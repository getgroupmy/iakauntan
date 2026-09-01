-- =====================================================================
-- iAkauntan :: the ledger is written only by functions
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ledger_is_written_only_by_functions.sql
--
-- `post_manual_journal` fixes the source, checks the accounts, checks
-- that debits equal credits and checks the period. Until `0399`,
-- `gl_entries` and `gl_lines` were also INSERTable straight from the
-- client, under a policy that checked only `app.can_post(org_id)` — no
-- period, no balance, no accounts. PostgREST publishes every table the
-- grants allow, so that was a second door, an HTTP request wide.
--
-- Measured before the fix, as an `accountant` with a period closed: an
-- entry dated inside the closed period went in, a single line of
-- 1,000,000 debit with no credit went in after it, and the entry header
-- then said debit 100 credit 100 while its own lines summed to
-- 1,000,000. `post_manual_journal`, given the same closed period,
-- refused it.
--
-- ---------------------------------------------------------------------
-- Everything here runs under `set local role authenticated`
--
-- This is the whole reason the file exists in this shape.
-- `pg_temp.sign_in_as` sets `request.jwt.claims` and does not change the
-- session role, so a test that only signs in still runs as the table
-- owner — and the owner is exempt from RLS and needs no grants. The
-- first measurement of this defect was made that way and was worthless:
-- it showed an insert succeeding that would have succeeded whatever the
-- policies said.
--
-- So: a role change, and a positive control that would fail if the role
-- change silently stopped working.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- Set up as the owner, then hand the ids to the authenticated section.
create temporary table t_ledger_ctx (
  org uuid, closed_period uuid, closed_on date, open_on date,
  asset uuid, revenue uuid, accountant uuid);
grant select on t_ledger_ctx to authenticated;

do $$
declare
  v_org uuid;
  v_owner uuid := pg_temp.test_user();
  v_acct uuid; v_period uuid; v_closed date; v_open date;
  v_asset uuid; v_revenue uuid;
begin
  v_org := pg_temp.test_org('Buku Besar Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  select id, start_date into v_period, v_closed
    from public.fiscal_periods where org_id = v_org
   order by start_date limit 1;
  update public.fiscal_periods set status = 'closed' where id = v_period;

  select start_date into v_open from public.fiscal_periods
   where org_id = v_org and status = 'open'
     and start_date <= current_date and end_date >= current_date limit 1;

  select a.id into v_asset from public.accounts a
   where a.org_id = v_org and not a.is_group and a.is_active
     and a.account_type = 'asset' order by a.code limit 1;
  select a.id into v_revenue from public.accounts a
   where a.org_id = v_org and not a.is_group and a.is_active
     and a.account_type = 'revenue' order by a.code limit 1;

  -- An accountant: `app.can_post` is true for them, and they are not an
  -- owner. This is the account the old policy admitted.
  v_acct := pg_temp.another_user('ledger@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_acct, 'accountant', 'active');

  insert into t_ledger_ctx values
    (v_org, v_period, v_closed, v_open, v_asset, v_revenue, v_acct);
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select accountant from t_ledger_ctx),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  c record;
  v_entry uuid;
  v_before bigint;
begin
  select * into c from t_ledger_ctx;

  -- The role change is itself asserted. Without it every insert below
  -- would succeed for a reason that has nothing to do with the policies,
  -- and the file would pass while proving nothing.
  perform pg_temp.check_eq('the session really is a client role',
    current_user, 'authenticated');
  perform pg_temp.check_true('and this member really may post',
    app.can_post(c.org));
  perform pg_temp.check_eq('the period really is closed',
    (select status from public.fiscal_periods where id = c.closed_period),
    'closed');

  v_before := (select count(*) from public.gl_entries where org_id = c.org);

  -- ------------------------------------------------------------------
  -- The door beside the door
  -- ------------------------------------------------------------------
  begin
    insert into public.gl_entries
      (org_id, entry_no, entry_date, fiscal_period_id, source, description,
       currency, exchange_rate, total_debit, total_credit, status)
    values (c.org, 'JV-DIRECT', c.closed_on, c.closed_period, 'manual',
            'Written straight to the table', 'MYR', 1, 100, 100, 'posted');
    raise exception
      'FAIL: an entry was written straight into gl_entries, in a closed period';
  exception when sqlstate '42501' then
    raise notice 'ok   the ledger cannot be written except through a function';
  end;

  perform pg_temp.check_eq('and nothing was written',
    (select count(*) from public.gl_entries where org_id = c.org), v_before);

  -- ------------------------------------------------------------------
  -- The door
  -- ------------------------------------------------------------------
  -- The positive control, and the reason `0239`'s was not one: posting
  -- is proved by posting, not by the presence of a grant. If revoking
  -- INSERT had broken the front door this is what would say so.
  v_entry := public.post_manual_journal(
    c.org, coalesce(c.open_on, current_date), jsonb_build_array(
      jsonb_build_object('account_id', c.asset,   'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', c.revenue, 'debit', 0, 'credit', 100)),
    'An ordinary journal', null);
  perform pg_temp.check_true('an ordinary journal still posts', v_entry is not null);
  perform pg_temp.check_eq('with both of its lines',
    (select count(*) from public.gl_lines where entry_id = v_entry), 2);
  -- The invariant the back door broke: the lines balance.
  --
  -- The entry header's own totals are deliberately not asserted here.
  -- `assert_balanced` is DEFERRABLE INITIALLY DEFERRED, so it maintains
  -- them at COMMIT, and this file rolls back -- they read zero for that
  -- reason and not because anything is wrong. `0238` documents the trap
  -- and `ledger_append_only.sql` forces the constraints and asserts the
  -- totals properly. Comparing the lines to each other is what this
  -- file is about anyway: it is the invariant the open door broke.
  perform pg_temp.check_eq('and its lines balance',
    (select sum(debit) from public.gl_lines where entry_id = v_entry),
    (select sum(credit) from public.gl_lines where entry_id = v_entry));

  -- The other half of the same door, and the more realistic use of it:
  -- an extra line appended to an entry that was posted legitimately.
  -- `assert_gl_balanced` fires on the entry, not on every line, so a
  -- line added afterwards is how a balanced journal stops balancing.
  -- Pointed at a real entry on purpose: with a made-up id the insert
  -- dies on the foreign key and proves nothing about permissions.
  begin
    insert into public.gl_lines
      (org_id, entry_id, line_no, account_id, description, debit, credit)
    values (c.org, v_entry, 99, c.asset, 'Appended afterwards', 1000000, 0);
    raise exception
      'FAIL: a line was appended to a posted entry, straight into gl_lines';
  exception when sqlstate '42501' then
    raise notice 'ok   nor can a line be appended to one that was';
  end;
  perform pg_temp.check_eq('so the entry still has the two lines it was posted with',
    (select count(*) from public.gl_lines where entry_id = v_entry), 2);

  -- And the guard that was being walked around still refuses.
  begin
    perform public.post_manual_journal(
      c.org, c.closed_on, jsonb_build_array(
        jsonb_build_object('account_id', c.asset,   'debit', 100, 'credit', 0),
        jsonb_build_object('account_id', c.revenue, 'debit', 0, 'credit', 100)),
      'Into a closed period', null);
    raise exception 'FAIL: the front door posted into a closed period';
  exception when others then
    raise notice 'ok   and a closed period is still closed to the front door';
  end;

  -- Reading is the half that has to survive.
  perform pg_temp.check_true('the ledger is still readable',
    (select count(*) from public.gl_entries where org_id = c.org) > 0);
  perform pg_temp.check_true('and so are its lines',
    (select count(*) from public.gl_lines where entry_id = v_entry) = 2);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- The grants themselves, so a later `grant all` cannot quietly undo it
-- ---------------------------------------------------------------------
do $$
declare v_left text;
begin
  select string_agg(distinct privilege_type, ', ' order by privilege_type)
    into v_left
    from information_schema.role_table_grants
   where grantee in ('authenticated', 'anon')
     and table_schema = 'public'
     and table_name in ('gl_entries', 'gl_lines');
  if v_left is distinct from 'SELECT' then
    raise exception
      'FAIL: a client role holds % on the ledger, expected SELECT only',
      coalesce(v_left, 'nothing');
  end if;
  raise notice 'ok   the client roles hold SELECT on the ledger and nothing else';

  if exists (select 1 from pg_policy p join pg_class t on t.oid = p.polrelid
              where t.relname in ('gl_entries', 'gl_lines') and p.polcmd = 'a')
  then
    raise exception 'FAIL: an insert policy on the ledger has come back';
  end if;
  raise notice 'ok   and there is no insert policy to go with it';
end $$;

rollback;
