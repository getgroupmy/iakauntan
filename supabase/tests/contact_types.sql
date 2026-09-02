-- =====================================================================
-- iAkauntan :: somebody you have not sold to yet
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/contact_types.sql
--
-- `prospect` joins the contact types. The value itself is a one-line
-- change; what this file is about is the thing that would have been
-- left behind — `import_contacts` validated against a list of five
-- names typed into the function, and printed a message naming three of
-- them.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org uuid;
  v_id  uuid;
  r     record;
  v_ok  integer := 0;
  v_bad integer := 0;
  v_msg text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Bakal Sdn Bhd');

  perform pg_temp.check_true('there is somewhere to put a prospect',
    exists (select 1 from unnest(enum_range(null::app.contact_type)) t
             where t::text = 'prospect'));

  -- One can be recorded, and stays one.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'P-001', 'Mungkin Sdn Bhd', 'prospect')
  returning id into v_id;
  perform pg_temp.check_eq('and one can be recorded',
    (select contact_type::text from public.contacts where id = v_id),
    'prospect');

  -- It is not a customer. The app asks for `customer` and `both` when
  -- it needs somebody to invoice, so this is what keeps a prospect off
  -- an invoice — no refusal was needed, and none was added.
  perform pg_temp.check_eq(
    'a prospect is not among the contacts you would invoice',
    (select count(*)::integer from public.contacts
      where org_id = v_org and contact_type in ('customer', 'both')), 0);

  -- ------------------------------------------------------------------
  -- The importer, which is where a bare enum change would have stopped
  -- ------------------------------------------------------------------
  for r in select * from public.import_contacts(
      v_org,
      jsonb_build_array(jsonb_build_object(
        'code', 'P-002', 'name', 'Barangkali Enterprise',
        'contact_type', 'prospect')),
      false)
  loop
    if r.status = 'error' then
      v_bad := v_bad + 1;
      v_msg := r.message;
    else
      v_ok := v_ok + 1;
    end if;
  end loop;

  perform pg_temp.check_eq('a file of prospects validates', v_ok, 1);
  perform pg_temp.check_eq('with nothing refused', v_bad, 0);

  -- And it really does import, not merely validate.
  perform public.import_contacts(
    v_org,
    jsonb_build_array(jsonb_build_object(
      'code', 'P-003', 'name', 'Entah Sdn Bhd', 'contact_type', 'prospect')),
    true);
  perform pg_temp.check_eq('and lands as a prospect',
    (select contact_type::text from public.contacts
      where org_id = v_org and code = 'P-003'), 'prospect');

  -- A type that is not one at all is still refused, and the message
  -- names every type there is rather than three of them.
  for r in select * from public.import_contacts(
      v_org,
      jsonb_build_array(jsonb_build_object(
        'code', 'X-001', 'name', 'Salah', 'contact_type', 'unicorn')),
      false)
  loop
    v_msg := r.message;
  end loop;
  perform pg_temp.check_true('a type that is not one is refused',
    v_msg like '%is not a contact type%');
  perform pg_temp.check_true('and the refusal lists all of them',
    v_msg like '%prospect%' and v_msg like '%employee%'
    and v_msg like '%customer%' and v_msg like '%supplier%');
end $$;

rollback;
