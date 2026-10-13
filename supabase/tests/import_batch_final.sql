-- =====================================================================
-- iAkauntan :: an import is finished once (0850)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/import_batch_final.sql
--
-- `rollback_import_batch` refuses a posted import, which has reached the
-- ledger. Before `0850` the status that said so could be moved back --
-- by `finish_import_batch` itself, or by hand -- and the rollback then
-- deleted the posted opening-balance journal. Asked as the owner, an
-- administrator, with the role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ib (org uuid, posted uuid, undone uuid, open uuid, entry uuid,
  cust uuid);
grant select on t_ib to authenticated;

do $$
declare r t_ib; v_dr uuid; v_cr uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Import Sekali Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, date_trunc('year', pg_temp.today())::date);
  select id into v_dr from public.accounts
   where org_id = r.org and account_type = 'asset' and not is_group order by code limit 1;
  select id into v_cr from public.accounts
   where org_id = r.org and account_type = 'equity' and not is_group order by code limit 1;

  -- The go-live: a customer and the opening balances, posted.
  r.posted := public.start_import_batch(r.org, 'autocount', 'Go-live');
  insert into public.contacts
    (org_id, code, name, contact_type, import_source, import_ref, import_batch_id, imported_at)
  values (r.org, 'D-1', 'Pelanggan Lama', 'customer', 'autocount', 'DEBTOR-1', r.posted, now())
  returning id into r.cust;
  insert into public.gl_entries
    (org_id, entry_no, entry_date, source, status, description,
     import_source, import_ref, import_batch_id, imported_at)
  values (r.org, 'OB-1', pg_temp.today(), 'manual', 'posted', 'Opening balances',
          'autocount', 'OB-1', r.posted, now())
  returning id into r.entry;
  insert into public.gl_lines (org_id, entry_id, line_no, account_id, debit, credit)
  values (r.org, r.entry, 1, v_dr, 50000, 0), (r.org, r.entry, 2, v_cr, 0, 50000);
  perform public.finish_import_batch(r.posted, 'posted', 'Went live');

  -- A rehearsal that failed and was rolled back.
  r.undone := public.start_import_batch(r.org, 'autocount', 'Rehearsal');
  perform public.finish_import_batch(r.undone, 'failed', 'Wrong file');
  perform public.rollback_import_batch(r.undone);

  -- And the one in progress: a company has one at a time.
  r.open := public.start_import_batch(r.org, 'autocount', 'Second rehearsal');
  insert into t_ib select r.*;

  perform pg_temp.check_eq('the premise: one posted, one rolled back, one staging',
    (select status from public.import_batches where id = r.posted) || ' / ' ||
    (select status from public.import_batches where id = r.undone) || ' / ' ||
    (select status from public.import_batches where id = r.open),
    'posted / rolled_back / staging');
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ib; n int; v_failing uuid;
begin
  select * into d from t_ib;
  perform pg_temp.check_true('the owner, asking as a client who administers',
    current_user = 'authenticated' and app.can_admin(d.org));

  -- What was measured.
  perform pg_temp.check_refused('a posted import is not finished again as failed',
    format($q$select public.finish_import_batch(%L, 'failed', 'Never mind')$q$, d.posted),
    'This import batch is posted, and stays so. A posted import has reached the ledger and '
    'is reversed with a journal; one rolled back has already been undone. A new run is a '
    'new batch.',
    '55000');
  perform pg_temp.check_refused('nor as reconciling',
    format($q$select public.finish_import_batch(%L, 'reconciling')$q$, d.posted),
    'This import batch is posted, and stays so.%', '55000');
  perform pg_temp.check_refused('nor put back to staging by hand',
    format($q$update public.import_batches set status = 'staging' where id = %L$q$, d.posted),
    'This import batch is posted, and stays so.%', '55000');
  perform pg_temp.check_refused('so it is still not rolled back',
    format('select * from public.rollback_import_batch(%L)', d.posted),
    '%Reverse it with a journal%', '55000');
  perform pg_temp.check_eq('and its journal and its customer stand',
    (select count(*)::text from public.gl_lines where entry_id = d.entry) || ' / ' ||
    (select count(*)::text from public.contacts where id = d.cust),
    '2 / 1');
  perform pg_temp.check_refused('one rolled back is not finished again either',
    format($q$select public.finish_import_batch(%L, 'posted')$q$, d.undone),
    'This import batch is rolled_back, and stays so.%', '55000');

  -- A status is moved by the functions, not by hand.
  perform pg_temp.check_refused('a staging batch is not marked posted by hand',
    format($q$update public.import_batches set status = 'posted' where id = %L$q$, d.open),
    'An import batch''s status moves through start_import_batch, finish_import_batch and '
    'rollback_import_batch, not by hand.',
    '42501');

  -- What the functions do is as before, and a label is still a label.
  update public.import_batches set label = 'Go-live, 1 January', notes = 'Checked'
   where id = d.posted;
  get diagnostics n = row_count;
  perform public.finish_import_batch(d.open, 'reconciling', 'Dry run read');
  perform public.finish_import_batch(d.open, 'posted', 'Went live after all');
  v_failing := public.start_import_batch(d.org, 'autocount', 'Third rehearsal');
  insert into public.contacts
    (org_id, code, name, contact_type, import_source, import_ref, import_batch_id, imported_at)
  values (d.org, 'D-3', 'Cubaan Ketiga', 'customer', 'autocount', 'DEBTOR-3', v_failing, now());
  perform public.finish_import_batch(v_failing, 'failed', 'Gave up');
  perform public.rollback_import_batch(v_failing);
  -- One more, left staging for the owner below.
  perform public.start_import_batch(d.org, 'autocount', 'Spare');
  perform pg_temp.check_eq('a posted batch is still relabelled, and a run still finishes and rolls back',
    n::text || ' / ' ||
    (select status from public.import_batches where id = d.open) || ' / ' ||
    (select status from public.import_batches where id = v_failing) || ' / ' ||
    (select count(*)::text from public.contacts where org_id = d.org and import_ref = 'DEBTOR-3'),
    '1 / posted / rolled_back / 0');
end $$;

reset role;

-- The database itself, as the owner, is not a client -- and still may
-- not reopen a posted import.
--
-- The guard's other door -- `pg_trigger_depth() > 1`, a statement one
-- trigger down -- has nothing to assert here, and its mutant survives as
-- an equivalent one: every import function is a definer, which runs as
-- the owner at any depth.
do $$
declare d t_ib; v_spare uuid;
begin
  select * into d from t_ib;
  select id into v_spare from public.import_batches where org_id = d.org and label = 'Spare';
  update public.import_batches set status = 'failed' where id = v_spare;
  perform pg_temp.check_eq('the owner, at the top, is not refused a status',
    (select status from public.import_batches where id = v_spare), 'failed');
  perform pg_temp.check_refused('but does not reopen a posted import either',
    format($q$update public.import_batches set status = 'failed' where id = %L$q$, d.posted),
    'This import batch is posted, and stays so.%', '55000');
end $$;

rollback;
