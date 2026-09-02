-- =====================================================================
-- iAkauntan :: the same company, typed by hand
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/contact_lookalikes.sql
--
-- 0477 links a company's records through `party_id`, but only the
-- record `create_contact_as` makes knew its party. 0481 is the rest:
-- a record typed by hand with the same registration number, ID or TIN
-- as one on file joins that record's party, and the editor is told
-- what is already on file before Save. What is asserted is what
-- counts as the same number, what does not, which records the editor
-- is told about and in what order, and that a record with a party
-- keeps it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- The codes `contact_lookalikes` answers with, in order, as one
-- string -- or the reason it refused.
create or replace function pg_temp.la(
  p_org uuid, p_type text, p_name text,
  p_reg text default null, p_tin text default null,
  p_id_type text default null, p_id text default null,
  p_exclude uuid default null)
returns text language plpgsql as $$
declare v text; v_msg text;
begin
  select coalesce(string_agg(
           (r ->> 'code') || ':' || (r ->> 'matched_on')
             || case when (r ->> 'same_role')::boolean then '!' else '' end,
           ' '), 'none')
    into v
    from jsonb_array_elements(public.contact_lookalikes(
           p_org, p_type::app.contact_type, p_name, p_reg, p_tin,
           p_id_type, p_id, p_exclude)) with ordinality t(r, n);
  return v;
exception when others then
  get stacked diagnostics v_msg = message_text;
  return v_msg;
end $$;

create or replace function pg_temp.party_of(p_id uuid)
returns uuid language sql stable as $$
  select party_id from public.contacts where id = p_id;
$$;

create or replace function pg_temp.cr_make(p_id uuid, p_as text)
returns text language plpgsql as $$
declare v_new uuid; v_msg text;
begin
  v_new := public.create_contact_as(p_id, p_as::app.contact_type);
  return (select code from public.contacts where id = v_new);
exception when others then
  get stacked diagnostics v_msg = message_text;
  return v_msg;
end $$;

-- ---------------------------------------------------------------------
-- What is a number
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('written with a dash, it is still the same number',
    app.identifying_number('1234567-X'), app.identifying_number('1234567x'));
  perform pg_temp.check_eq('and spaces and brackets are not part of it',
    app.identifying_number('202001012345 (1234567-X)'),
    '2020010123451234567X');
  perform pg_temp.check_true('N/A is not a registration number',
    app.identifying_number('N/A') is null
    and app.identifying_number('NIL') is null
    and app.identifying_number('-') is null
    and app.identifying_number('') is null
    and app.identifying_number(null) is null
    and app.identifying_number('000000') is null);
  perform pg_temp.check_true('LHDN''s general TIN is not anybody''s',
    app.identifying_number('EI00000000010') is null
    and app.identifying_number('EI00000000020') is null
    and app.identifying_number('EI00000000040') is null);
  perform pg_temp.check_eq('a company''s own TIN is',
    app.identifying_number('c12345678900'), 'C12345678900');
  perform pg_temp.check_eq('a name is compared with its dots folded',
    app.comparable_name('AL HARDWARE SDN. BHD.'),
    app.comparable_name('Al  Hardware Sdn Bhd'));
end $$;

-- ---------------------------------------------------------------------
-- Al Hardware, filed as a supplier, typed in again as a customer
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_other uuid;
  v_yr    text;
  v_sup   uuid;
  v_cust  uuid;
  v_pro   uuid;
  v_ali   uuid;
  v_r     jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Perkakasan Dua Sdn Bhd');
  v_yr := to_char(app.today(), 'YYYY');

  insert into public.contacts (
    org_id, code, name, contact_type, tin, registration_no,
    id_type, id_value)
  values (
    v_org, 'S-' || v_yr || '-00001', 'Al Hardware Sdn Bhd', 'supplier',
    'C12345678900', '202001012345', 'BRN', '202001012345')
  returning id into v_sup;

  perform pg_temp.check_true('the first record of a company has no party yet',
    pg_temp.party_of(v_sup) is null);

  -- The editor, with a customer half typed.
  perform pg_temp.check_eq('typing the registration number finds the supplier',
    pg_temp.la(v_org, 'customer', 'Al Hardware', '2020-01-012345'),
    'S-' || v_yr || '-00001:registration_no');
  perform pg_temp.check_eq('and as a supplier, it is already on file',
    pg_temp.la(v_org, 'supplier', 'Al Hardware', '202001012345'),
    'S-' || v_yr || '-00001:registration_no!');
  perform pg_temp.check_eq('Both counts as the supplier role too',
    pg_temp.la(v_org, 'both', 'Al Hardware', '202001012345'),
    'S-' || v_yr || '-00001:registration_no!');
  perform pg_temp.check_eq('the TIN finds it',
    pg_temp.la(v_org, 'customer', 'Somebody', null, 'c12345678900'),
    'S-' || v_yr || '-00001:tin');
  perform pg_temp.check_eq('the ID finds it',
    pg_temp.la(v_org, 'customer', 'Somebody', null, null, 'BRN',
               '202001012345'),
    'S-' || v_yr || '-00001:id');
  perform pg_temp.check_eq('an NRIC is not a BRN with the same digits',
    pg_temp.la(v_org, 'customer', 'Somebody', null, null, 'NRIC',
               '202001012345'),
    'none');
  perform pg_temp.check_eq('the name alone finds it, and says so',
    pg_temp.la(v_org, 'customer', 'AL HARDWARE SDN. BHD.'),
    'S-' || v_yr || '-00001:name');
  perform pg_temp.check_eq('a different company is not a lookalike',
    pg_temp.la(v_org, 'customer', 'Ali Hardware Sdn Bhd', '199901000001'),
    'none');
  perform pg_temp.check_eq('N/A in the registration column finds nothing',
    pg_temp.la(v_org, 'customer', 'Ali Hardware Sdn Bhd', 'N/A', 'N/A'),
    'none');
  perform pg_temp.check_eq('a record is not its own lookalike',
    pg_temp.la(v_org, 'supplier', 'Al Hardware Sdn Bhd', '202001012345',
               'C12345678900', 'BRN', '202001012345', v_sup),
    'none');

  -- Typed in anyway, as a customer.
  insert into public.contacts (
    org_id, code, name, contact_type, registration_no, id_type, id_value)
  values (
    v_org, 'C-' || v_yr || '-00013', 'Al Hardware Sdn Bhd', 'customer',
    '2020-01-012345', 'BRN', '2020-01-012345')
  returning id into v_cust;

  perform pg_temp.check_eq('typed by hand, the customer record joins the supplier''s party',
    pg_temp.party_of(v_cust), v_sup);
  perform pg_temp.check_eq('and the supplier record is the party',
    pg_temp.party_of(v_sup), v_sup);
  perform pg_temp.check_eq('the supplier record is otherwise untouched',
    (select code || ' ' || contact_type || ' ' || registration_no
       from public.contacts where id = v_sup),
    'S-' || v_yr || '-00001 supplier 202001012345');

  -- What 0477 built now sees the hand-typed record.
  v_r := public.contact_records(v_sup);
  perform pg_temp.check_eq('the sheet on the supplier shows the customer record',
    (select string_agg(r ->> 'code', ',')
       from jsonb_array_elements(v_r -> 'records') r),
    'C-' || v_yr || '-00013');
  perform pg_temp.check_eq('and create_contact_as will not make a second customer record',
    pg_temp.cr_make(v_sup, 'customer'),
    'Al Hardware Sdn Bhd already has a customer record, C-' || v_yr
      || '-00013');
  perform pg_temp.check_eq('but a prospect record can still be made from either',
    left(pg_temp.cr_make(v_cust, 'prospect'), 2), 'P-');
  select id into v_pro from public.contacts
   where org_id = v_org and contact_type = 'prospect';
  perform pg_temp.check_eq('and it is in the same party',
    pg_temp.party_of(v_pro), v_sup);

  -- The editor, now that there are three: the role being typed first.
  perform pg_temp.check_eq('the records in the role being typed come first',
    pg_temp.la(v_org, 'customer', 'Al Hardware', '202001012345'),
    'C-' || v_yr || '-00013:registration_no! '
      || 'P-' || v_yr || '-00001:registration_no '
      || 'S-' || v_yr || '-00001:registration_no');

  -- A name alone links nothing -- not even the same name to the
  -- letter, on a record whose own TIN matches nobody.
  insert into public.contacts (org_id, code, name, contact_type, tin)
  values (v_org, 'C-' || v_yr || '-00014', 'Al Hardware Sdn Bhd', 'customer',
          'C99999999999')
  returning id into v_ali;
  perform pg_temp.check_true('a name alone links nothing',
    pg_temp.party_of(v_ali) is null);

  -- Until an identifier is typed on it.
  update public.contacts set tin = 'C12345678900' where id = v_ali;
  perform pg_temp.check_eq('an identifier added later links the record then',
    pg_temp.party_of(v_ali), v_sup);

  -- And once it has a party, it keeps it -- even when a number typed
  -- on it later is another company's. That is a wrong number on a
  -- known record, not a change of company, and the editor said so.
  insert into public.contacts (org_id, code, name, contact_type,
                               registration_no)
  values (v_org, 'S-' || v_yr || '-00002', 'Ali Hardware Sdn Bhd',
          'supplier', '199901000001');
  update public.contacts set registration_no = '199901000001'
   where id = v_ali;
  perform pg_temp.check_eq('a record that has a party keeps it',
    pg_temp.party_of(v_ali), v_sup);

  -- A record with no identifiers at all is not in the trigger's way.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-' || v_yr || '-00015', 'Walk-in', 'customer');

  -- Another company's contacts are not looked at.
  v_other := pg_temp.test_org('Syarikat Lain Sdn Bhd');
  perform pg_temp.check_eq('another company''s contacts are not looked at',
    pg_temp.la(v_other, 'customer', 'Al Hardware', '202001012345'),
    'none');
  insert into public.contacts (
    org_id, code, name, contact_type, registration_no)
  values (v_other, 'S-1', 'Al Hardware Sdn Bhd', 'supplier', '202001012345')
  returning id into v_ali;
  perform pg_temp.check_true('and the same number there is its own party',
    pg_temp.party_of(v_ali) is null);

  -- Somebody outside the company.
  perform pg_temp.sign_in_as(pg_temp.another_user('luar@lookalike.test'));
  perform pg_temp.check_eq('somebody outside the company is refused',
    pg_temp.la(v_org, 'customer', 'Al Hardware', '202001012345'),
    'Not a member of that company');
end $$;

rollback;
