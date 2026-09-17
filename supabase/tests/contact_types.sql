-- =====================================================================
-- iAkauntan :: somebody you have not sold to yet
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/contact_types.sql
--
-- `app.contact_type` gained a sixth value in 0471: `prospect`, for the
-- company you are talking to and have not sold to. Adding the value is
-- the easy half. The half that goes wrong quietly is every list of
-- those names typed somewhere else -- `import_contacts` validated
-- against five of them and printed three, so a file of prospects would
-- have been refused row by row with advice that was already wrong
-- before the sixth value existed.
--
-- So what is asserted here is not "the enum has six values". It is that
-- nothing else holds a copy of the list.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- One import, run in validate mode, reduced to the one row's verdict.
create or replace function pg_temp.ct_check(p_org uuid, p_type text)
returns text language sql as $$
  select r.status || ': ' || r.message
    from public.import_contacts(
      p_org,
      jsonb_build_array(jsonb_build_object(
        'code', 'X' || upper(p_type), 'name', 'Syarikat ' || p_type,
        'contact_type', p_type)),
      false) r;
$$;

-- ---------------------------------------------------------------------
-- The value itself
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('prospect is a contact type',
    exists (select 1
              from pg_enum e
              join pg_type t on t.oid = e.enumtypid
              join pg_namespace n on n.oid = t.typnamespace
             where n.nspname = 'app'
               and t.typname = 'contact_type'
               and e.enumlabel = 'prospect'));

  -- The five that were there before are still there. An `alter type`
  -- cannot drop a value, but a restated type in a later migration can,
  -- and this is the assertion that would notice.
  perform pg_temp.check_eq('and the ones before it are untouched',
    (select string_agg(e.enumlabel, ',' order by e.enumsortorder)
       from pg_enum e
       join pg_type t on t.oid = e.enumtypid
       join pg_namespace n on n.oid = t.typnamespace
      where n.nspname = 'app' and t.typname = 'contact_type'),
    'customer,supplier,both,employee,other,prospect');
end $$;

-- ---------------------------------------------------------------------
-- A file of prospects
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_out text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Bakal Pelanggan Sdn Bhd');

  -- One can be recorded by hand, which is the enum cast and nothing
  -- else -- asserted separately from the importer so that a failure
  -- says which of the two broke.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'P-001', 'Mungkin Sdn Bhd', 'prospect');
  perform pg_temp.check_eq('a prospect can be recorded',
    (select c.contact_type::text from public.contacts c
      where c.org_id = v_org and c.code = 'P-001'), 'prospect');

  -- The mutant that matters: the five names typed back into the check.
  -- It dies here, on `error` where `ok` was expected.
  perform pg_temp.check_eq('a file of prospects validates',
    pg_temp.ct_check(v_org, 'prospect'), 'ok: ');

  -- Not at the expense of the five it already took.
  perform pg_temp.check_eq('and so does a customer',
    pg_temp.ct_check(v_org, 'customer'), 'ok: ');
  perform pg_temp.check_eq('and a supplier',
    pg_temp.ct_check(v_org, 'supplier'), 'ok: ');
  perform pg_temp.check_eq('and both',
    pg_temp.ct_check(v_org, 'both'), 'ok: ');
  perform pg_temp.check_eq('and an employee',
    pg_temp.ct_check(v_org, 'employee'), 'ok: ');
  perform pg_temp.check_eq('and other',
    pg_temp.ct_check(v_org, 'other'), 'ok: ');

  -- Something that is not a contact type is still refused.
  v_out := pg_temp.ct_check(v_org, 'client');
  perform pg_temp.check_true('and something that is not one is refused',
    v_out like 'error: "client" is not a contact type%');

  -- The second mutant: the message typed back to naming three of them.
  -- Worth its own assertion. A refusal that is correct and then tells
  -- you the wrong way to fix it costs somebody the same afternoon as a
  -- refusal that is wrong.
  perform pg_temp.check_true('and the refusal lists all of them',
    v_out like '%both%' and v_out like '%customer%'
    and v_out like '%employee%' and v_out like '%other%'
    and v_out like '%prospect%' and v_out like '%supplier%');

  -- It commits, too -- validating a type the insert would then reject
  -- on the cast is a way of passing this file and failing in the app.
  perform * from public.import_contacts(
    v_org,
    jsonb_build_array(jsonb_build_object(
      'code', 'P1', 'name', 'Bakal Pelanggan', 'contact_type', 'prospect')),
    true);
  perform pg_temp.check_eq('and a prospect is a prospect once imported',
    (select c.contact_type::text from public.contacts c
      where c.org_id = v_org and c.code = 'P1'), 'prospect');

  -- And it is not one of the customers. This is the whole reason the
  -- value exists: a pipeline recorded as customers overstates the
  -- customer list, and every report built on that list with it.
  perform pg_temp.check_eq('and it is not counted as a customer',
    (select count(*) from public.contacts c
      where c.org_id = v_org and c.code = 'P1'
        and c.contact_type in ('customer', 'both')), 0::bigint);
end $$;

-- ---------------------------------------------------------------------
-- What did not change
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_lead uuid;
  v_res  jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Tukar Petunjuk Sdn Bhd');

  insert into public.leads (org_id, lead_no, company_name, status)
  values (v_org, 'LD-001', 'Sudah Beli Sdn Bhd', 'qualified')
  returning id into v_lead;

  v_res := public.convert_lead(v_lead, false);

  -- Deliberate, and asserted so that a later reading of "a lead is a
  -- prospect" does not quietly move it. A lead worth converting is one
  -- that has bought; a prospect is where a contact starts before there
  -- is a lead at all.
  perform pg_temp.check_eq('converting a lead still makes a customer',
    (select c.contact_type::text from public.contacts c
      where c.id = (v_res ->> 'contact_id')::uuid), 'customer');
end $$;

rollback;
