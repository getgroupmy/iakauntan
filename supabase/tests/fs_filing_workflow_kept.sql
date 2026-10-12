-- =====================================================================
-- iAkauntan :: a filing is lodged by lodging it (0838)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fs_filing_workflow_kept.sql
--
-- A set of accounts for SSM is frozen by `fs_freeze`, lodged by
-- `fs_lodge`, and once lodged cannot be reopened -- `fs_unfreeze`
-- refuses. Before `0838` a client wrote the status itself: a draft
-- marked lodged that was never frozen, and a lodged set put back to
-- draft, its audit opinion rewritten, and lodged again. Asked as the
-- owner with the role `authenticated`, as the filing screens ask.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_fw (org uuid, u uuid, filing uuid);
grant select on t_fw to authenticated;

-- A posted journal, two lines.
create or replace function pg_temp.jv(
  p_org uuid, p_no text, p_date date,
  p_dr uuid, p_cr uuid, p_amount numeric)
returns void language plpgsql as $$
declare v_entry uuid;
begin
  insert into public.gl_entries
    (org_id, entry_no, entry_date, source, status, description)
  values (p_org, p_no, p_date, 'manual', 'posted', p_no)
  returning id into v_entry;
  insert into public.gl_lines (org_id, entry_id, line_no, account_id, debit, credit)
  values (p_org, v_entry, 1, p_dr, p_amount, 0),
         (p_org, v_entry, 2, p_cr, 0, p_amount);
end $$;

create or replace function pg_temp.acct(p_org uuid, p_subtype text)
returns uuid language sql as $$
  select id from public.accounts
   where org_id = p_org and account_subtype = p_subtype::app.account_subtype
     and not is_group
   order by code limit 1;
$$;

do $$
declare r t_fw;
begin
  r.u := pg_temp.test_user();
  perform pg_temp.sign_in_as(r.u);
  r.org := pg_temp.test_org('Akaun Tahunan Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (r.org, 'mbrs', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform public.create_fiscal_year(r.org, date '2025-01-01');
  perform pg_temp.jv(r.org, 'JV-1', date '2025-01-02',
    pg_temp.acct(r.org, 'bank'), pg_temp.acct(r.org, 'share_capital'), 100000);
  perform pg_temp.jv(r.org, 'JV-2', date '2025-06-30',
    pg_temp.acct(r.org, 'bank'), pg_temp.acct(r.org, 'sales'), 250000);
  insert into t_fw select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_fw; v uuid; r record;
begin
  select * into d from t_fw;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');

  -- The screen makes a draft and fills it in.
  insert into public.fs_filings
    (org_id, fy_start, fy_end, framework, audit_status, employee_count)
  values (d.org, date '2025-01-01', date '2025-12-31', 'mpers', 'audited', 3)
  returning id into v;
  update public.fs_filings
     set auditor_name = 'Tan & Partners', auditor_firm_no = 'AF 1234',
         opinion = 'unmodified', audit_report_date = date '2026-04-15',
         directors_approval_date = date '2026-04-15',
         circulated_on = date '2026-04-20', notes = 'Year one'
   where id = v;
  perform pg_temp.check_eq('the screen still writes what it writes',
    (select opinion::text || ' / ' || notes from public.fs_filings where id = v),
    'unmodified / Year one');

  -- What was measured: lodged by hand, never frozen.
  perform pg_temp.check_refused('a draft is not marked lodged by hand',
    format('update public.fs_filings set status = ''lodged'', lodged_on = %L, mbrs_reference = %L where id = %L',
           date '2026-05-02', 'MBRS-1', v),
    'The status of these accounts moves when they are frozen, unfrozen or lodged, not by hand.',
    '42501');
  -- Each workflow column on its own.
  for r in select * from (values
      ('status', '''frozen'''),
      ('frozen_at', 'now()'),
      ('frozen_by', quote_literal(d.u))) as t(col, val)
  loop
    perform pg_temp.check_refused(format('nor its %s', r.col),
      format('update public.fs_filings set %s = %s where id = %L', r.col, r.val, v),
      format('The %s of these accounts moves%%', r.col), '42501');
  end loop;
  -- Nor is one made already frozen or lodged.
  perform pg_temp.check_refused('a set of accounts is not made lodged',
    format($q$insert into public.fs_filings (org_id, fy_start, fy_end, audit_status, status)
              values (%L, date '2024-01-01', date '2024-12-31', 'audited', 'lodged')$q$, d.org),
    'A set of accounts starts as a draft.%', '42501');
  perform pg_temp.check_refused('nor stamped frozen',
    format($q$insert into public.fs_filings (org_id, fy_start, fy_end, audit_status, frozen_at)
              values (%L, date '2024-01-01', date '2024-12-31', 'audited', now())$q$, d.org),
    'A set of accounts starts as a draft.%', '42501');
  perform pg_temp.check_refused('nor signed as frozen by somebody',
    format($q$insert into public.fs_filings (org_id, fy_start, fy_end, audit_status, frozen_by)
              values (%L, date '2024-01-01', date '2024-12-31', 'audited', %L)$q$, d.org, d.u),
    'A set of accounts starts as a draft.%', '42501');

  -- The functions move it.
  perform public.fs_freeze(v);
  perform pg_temp.check_true('fs_freeze freezes it, and says when and who',
    (select status = 'frozen' and frozen_at is not null and frozen_by = d.u
       from public.fs_filings where id = v));
  perform public.fs_lodge(v, 'MBRS-2026-000123', date '2026-05-02');
  perform pg_temp.check_eq('fs_lodge lodges it',
    (select status::text from public.fs_filings where id = v), 'lodged');

  -- And what was measured the other way: reopened by hand to rewrite.
  perform pg_temp.check_refused('a lodged set is not put back to draft by hand',
    format('update public.fs_filings set status = ''draft'' where id = %L', v),
    'The status of these accounts moves%', '42501');
  perform pg_temp.check_refused('as fs_unfreeze refuses',
    format('select public.fs_unfreeze(%L)', v),
    'These accounts have been lodged with SSM and cannot be reopened.%');
  perform pg_temp.check_refused('and its figures stay as lodged',
    format('update public.fs_filings set opinion = ''qualified'' where id = %L', v),
    'These accounts have been lodged with SSM.%', '42501');

  -- A typo in what mPortal returned is a typo.
  update public.fs_filings
     set mbrs_reference = 'MBRS-2026-000132', lodged_on = date '2026-05-03'
   where id = v;
  perform pg_temp.check_eq('the reference and the lodgement date stay open',
    (select mbrs_reference || ' ' || lodged_on from public.fs_filings where id = v),
    'MBRS-2026-000132 2026-05-03');
end $$;

reset role;

-- The database itself, as the owner, is not a client.
--
-- The guard's other door -- `pg_trigger_depth() > 1`, a statement one
-- trigger down -- has nothing to assert here, and its mutant survives as
-- an equivalent one: fs_freeze, fs_unfreeze and fs_lodge are definers,
-- which run as the owner at any depth.
do $$
declare d t_fw;
begin
  select * into d from t_fw;
  insert into public.fs_filings (org_id, fy_start, fy_end, audit_status, status)
  values (d.org, date '2024-01-01', date '2024-12-31', 'audited', 'frozen');
  perform pg_temp.check_eq('the owner, at the top, is not refused',
    (select status::text from public.fs_filings
      where org_id = d.org and fy_end = date '2024-12-31'), 'frozen');
end $$;

rollback;
