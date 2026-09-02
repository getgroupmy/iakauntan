-- =====================================================================
-- The duplicates already on file
-- =====================================================================
-- 0481 links the records of one company as they are typed. What was
-- typed before it stays as it was: Al Hardware filed as a supplier in
-- March and typed in again as a customer in June is two records that
-- do not know of each other. 0482 reports those, links them when
-- somebody says so, and lets one out again when the number that put
-- it there was a typing mistake.
--
-- The fixtures below make that history the way it really looks --
-- records that carry the same number and carry no party -- by
-- clearing `party_id` after the insert, which is what every record
-- older than 0481 has in it.
-- =====================================================================
\i supabase/tests/_helpers.sql

begin;

-- The report, as one line: each group as `matched_on:CODE+CODE`.
create or replace function pg_temp.dups(p_org uuid)
returns text language plpgsql as $$
declare v text;
begin
  select coalesce(string_agg(
           (g ->> 'matched_on') || ':' || (
             select string_agg(r ->> 'code', '+' order by r ->> 'code')
               from jsonb_array_elements(g -> 'records') r), ' | '), 'none')
    into v
    from jsonb_array_elements(public.contact_duplicates(p_org)) g;
  return v;
exception when others then return SQLERRM;
end $$;

create or replace function pg_temp.link(p_org uuid, p_ids uuid[])
returns text language plpgsql as $$
declare v jsonb;
begin
  v := public.link_contact_records(p_org, p_ids);
  return (v ->> 'code') || ' ' || (v ->> 'records') || ' records';
exception when others then return SQLERRM;
end $$;

create or replace function pg_temp.unlink(p_id uuid)
returns text language plpgsql as $$
begin
  return public.unlink_contact_record(p_id) ->> 'code';
exception when others then return SQLERRM;
end $$;

create or replace function pg_temp.party_of(p_id uuid)
returns uuid language sql stable as $$
  select party_id from public.contacts where id = p_id;
$$;

do $$
declare
  v_org    uuid;
  v_other  uuid;
  v_yr     text := to_char(app.today(), 'YYYY');
  v_sup    uuid;
  v_cust   uuid;
  v_pro    uuid;
  v_gone   uuid;
  v_viewer uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Perkakasan Tiga Sdn Bhd');

  -- March: the supplier.
  insert into public.contacts (org_id, code, name, contact_type,
                               registration_no, tin, created_at)
  values (v_org, 'S-' || v_yr || '-00001', 'Al Hardware Sdn Bhd',
          'supplier', '202001012345', 'C12345678900',
          now() - interval '3 months')
  returning id into v_sup;

  -- June: the same company, typed again by somebody who did not look.
  insert into public.contacts (org_id, code, name, contact_type,
                               registration_no, tin, created_at)
  values (v_org, 'C-' || v_yr || '-00013', 'AL HARDWARE SDN. BHD.',
          'customer', '2020-01-012345', 'C12345678900',
          now() - interval '1 month')
  returning id into v_cust;

  -- As they were before 0481: two records, no party between them.
  update public.contacts set party_id = null where org_id = v_org;

  perform pg_temp.check_eq('the same registration number, typed twice, '
    'is a duplicate',
    pg_temp.dups(v_org),
    'registration_no:C-' || v_yr || '-00013+S-' || v_yr || '-00001');

  -- The TIN is the same too, and it is the same pair of records: one
  -- group, reported under the stronger identifier.
  perform pg_temp.check_true('the same records found twice are reported once',
    jsonb_array_length(public.contact_duplicates(v_org)) = 1);

  -- A column an import file had nothing for.
  insert into public.contacts (org_id, code, name, contact_type,
                               registration_no)
  values (v_org, 'C-' || v_yr || '-00014', 'Kedai Satu', 'customer', 'N/A'),
         (v_org, 'C-' || v_yr || '-00015', 'Kedai Dua', 'customer', 'N/A'),
         (v_org, 'C-' || v_yr || '-00018', 'Kedai Tiga', 'customer', 'NIL'),
         (v_org, 'C-' || v_yr || '-00019', 'Kedai Empat', 'customer', 'NIL');
  perform pg_temp.check_eq('N/A is not a duplicate of N/A',
    pg_temp.dups(v_org),
    'registration_no:C-' || v_yr || '-00013+S-' || v_yr || '-00001');

  -- The same digits, one an NRIC and one a BRN.
  insert into public.contacts (org_id, code, name, contact_type,
                               id_type, id_value)
  values (v_org, 'C-' || v_yr || '-00016', 'Encik Samad', 'customer',
          'NRIC', '880101015566'),
         (v_org, 'S-' || v_yr || '-00002', 'Samad Trading', 'supplier',
          'BRN', '880101015566');
  perform pg_temp.check_eq('an NRIC and a BRN are not the same number',
    pg_temp.dups(v_org),
    'registration_no:C-' || v_yr || '-00013+S-' || v_yr || '-00001');

  -- A record somebody has already deleted is not on file.
  insert into public.contacts (org_id, code, name, contact_type,
                               registration_no, deleted_at)
  values (v_org, 'C-' || v_yr || '-00017', 'Al Hardware (lama)', 'customer',
          '202001012345', now())
  returning id into v_gone;
  update public.contacts set party_id = null where id = v_gone;
  perform pg_temp.check_eq('a deleted record is not a duplicate',
    pg_temp.dups(v_org),
    'registration_no:C-' || v_yr || '-00013+S-' || v_yr || '-00001');

  -- Another company, with the same numbers in it.
  v_other := pg_temp.test_org('Syarikat Empat Sdn Bhd');
  insert into public.contacts (org_id, code, name, contact_type,
                               registration_no)
  values (v_other, 'S-' || v_yr || '-00001', 'Al Hardware Sdn Bhd',
          'supplier', '202001012345');
  perform pg_temp.check_true('another company''s records are not grouped '
    'with ours',
    public.contact_duplicates(v_other) = '[]'::jsonb);
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- What linking refuses.
  perform pg_temp.check_eq('one record is not a link',
    pg_temp.link(v_org, array[v_sup]),
    'Two records or more make a company');
  perform pg_temp.check_eq('a record from another company cannot be '
    'linked in',
    pg_temp.link(v_org, array[v_sup,
      (select id from public.contacts where org_id = v_other)]),
    'Those are not all records of this company');
  perform pg_temp.check_true('and nothing was linked',
    pg_temp.party_of(v_sup) is null);

  -- The prospect made from the customer, which came with a party of
  -- its own -- the customer's -- and must come along.
  v_pro := public.create_contact_as(v_cust, 'prospect');
  perform pg_temp.check_eq('the prospect is the customer''s',
    pg_temp.party_of(v_pro), v_cust);

  perform pg_temp.check_eq('the record filed first is the company',
    pg_temp.link(v_org, array[v_cust, v_sup]),
    'S-' || v_yr || '-00001 3 records');
  perform pg_temp.check_eq('linking one record brings its records with it',
    pg_temp.party_of(v_pro), v_sup);
  perform pg_temp.check_eq('and the customer is in the same company',
    pg_temp.party_of(v_cust), v_sup);
  perform pg_temp.check_eq('the record filed first is the party',
    pg_temp.party_of(v_sup), v_sup);
  perform pg_temp.check_eq('once linked, it is not reported again',
    pg_temp.dups(v_org), 'none');

  -- The sheet on any of them now shows all three.
  perform pg_temp.check_eq('the sheet shows the company, not the record',
    (select string_agg(r ->> 'code', ',' order by r ->> 'code')
       from jsonb_array_elements(
              public.contact_records(v_sup) -> 'records') r),
    'C-' || v_yr || '-00013,P-' || v_yr || '-00001');

  -- And the way back, for a number that was a typing mistake.
  perform pg_temp.check_eq('unlinking one leaves the others together',
    pg_temp.unlink(v_pro), 'P-' || v_yr || '-00001');
  perform pg_temp.check_true('the record that left has no company',
    pg_temp.party_of(v_pro) is null);
  perform pg_temp.check_eq('and the two that stayed still have theirs',
    pg_temp.party_of(v_cust), v_sup);
  perform pg_temp.check_eq('which the sheet shows',
    (select string_agg(r ->> 'code', ',' order by r ->> 'code')
       from jsonb_array_elements(
              public.contact_records(v_sup) -> 'records') r),
    'C-' || v_yr || '-00013');

  -- And it is reported again, because it still carries the number
  -- that put it there. Unlinking says these are not one company; it
  -- does not say what the number is. Correcting the number is the
  -- other half, and until it is corrected the report is right to ask.
  perform pg_temp.check_eq('the record that left still carries the number',
    pg_temp.dups(v_org),
    'registration_no:C-' || v_yr || '-00013+P-' || v_yr || '-00001+S-'
      || v_yr || '-00001');

  -- A member who may only read.
  v_viewer := pg_temp.another_user('lihat@pendua.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_viewer, 'viewer', 'active', now());
  perform pg_temp.sign_in_as(v_viewer);
  perform pg_temp.check_eq('somebody who may only read may look',
    pg_temp.dups(v_org),
    'registration_no:C-' || v_yr || '-00013+P-' || v_yr || '-00001+S-'
      || v_yr || '-00001');
  perform pg_temp.check_eq('somebody who may only read cannot link',
    pg_temp.link(v_org, array[v_cust, v_pro]), 'Insufficient privileges');
  perform pg_temp.check_eq('and cannot unlink',
    pg_temp.unlink(v_cust), 'Insufficient privileges');
  perform pg_temp.check_eq('and nothing moved',
    pg_temp.party_of(v_cust), v_sup);

  -- A stranger.
  perform pg_temp.sign_in_as(pg_temp.another_user('luar@pendua.test'));
  perform pg_temp.check_eq('somebody outside the company is refused',
    pg_temp.dups(v_org), 'Not a member of that company');

  raise notice 'contact duplicates: all assertions passed';
end $$;

rollback;
