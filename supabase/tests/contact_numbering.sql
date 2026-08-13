-- =====================================================================
-- iAkauntan :: contact codes that are actually free
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/contact_numbering.sql
--
-- `app.next_document_number_internal` counts; it does not check. A code
-- can reach `contacts` without ever passing through it — the CSV
-- importer writes whatever the file said, and an organization can be
-- seeded with contacts already numbered — so the counter can sit at 1
-- while `C-2026-00001` is taken, and the next contact anybody creates
-- fails on `contacts_org_id_code_key`.
--
-- That is not hypothetical: it is what a live organization did the first
-- time a supplier was created from a scanned bill. It does not heal by
-- itself either — the same number comes back until something moves the
-- sequence past it.
--
-- Asserted here:
--
--   * the collision is real, so the fix is not guarding against nothing;
--   * 0116 moves each contact counter past what its organization
--     already holds, and the next number is then free;
--   * only codes shaped like that sequence's own output count — an `S-`
--     code cannot collide with a `C-` one and must not push it along;
--   * the counter only ever moves forward, so a deleted code is not
--     handed out a second time.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- The re-sync from 0116, as a function so the test can run it at the
-- point a fresh collision has been set up rather than only at migration
-- time. Kept byte-identical in substance to the migration; if one
-- changes and the other does not, this test is what says so.
create or replace function pg_temp.resync_contact_numbers()
returns void language plpgsql as $$
declare
  v_org uuid; v_seq record; v_period text; v_pattern text; v_max bigint;
begin
  for v_org in select distinct org_id from public.contacts loop
    insert into public.number_sequences (org_id, doc_type, prefix)
    values (v_org, 'contact', app.default_doc_prefix('contact'))
    on conflict (org_id, doc_type) do nothing;
  end loop;

  for v_seq in select * from public.number_sequences where doc_type = 'contact' loop
    v_period := case v_seq.reset_policy
      when 'yearly' then to_char(current_date, 'YYYY')
      when 'monthly' then to_char(current_date, 'YYYYMM')
      else null end;
    v_pattern := '^' || regexp_replace(coalesce(v_seq.prefix, ''), '([.^$*+?()\[\]{}|\\])', '\\\1', 'g')
      || coalesce(v_period || '-', '') || '(\d+)'
      || regexp_replace(coalesce(v_seq.suffix, ''), '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '$';
    select max((regexp_match(c.code, v_pattern))[1]::bigint) into v_max
      from public.contacts c where c.org_id = v_seq.org_id and c.code ~ v_pattern;
    if v_max is not null and v_seq.next_value <= v_max then
      update public.number_sequences
         set next_value = v_max + 1, period_key = coalesce(v_period, period_key)
       where id = v_seq.id;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- A seeded organization: contacts numbered by hand, counter untouched
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Numbering Sdn Bhd');
  v_year text := to_char(current_date, 'YYYY');
  v_taken text;
  v_failed boolean := false;
begin
  -- Exactly what a seed or an import does: a code written straight in.
  v_taken := 'C-' || v_year || '-00001';
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, v_taken, 'Bumi Maju Enterprise', 'customer');

  -- And a supplier under a different prefix, which must not count.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-' || v_year || '-00009', 'Teguh Hardware Sdn Bhd', 'supplier');

  -- The counter has never been used, so it is about to hand out a code
  -- that is already on the table.
  perform pg_temp.check_eq('the counter starts where the seed left it',
    (select next_value from public.number_sequences
      where org_id = v_org and doc_type = 'contact'), null);

  -- Proving the collision rather than assuming it.
  begin
    insert into public.contacts (org_id, code, name, contact_type)
    values (v_org, app.next_document_number_internal(v_org, 'contact'),
            'Kedai Runcit Aman', 'supplier');
  exception when unique_violation then
    v_failed := true;
  end;
  perform pg_temp.check_true('an unsynced counter collides with a seeded code',
    v_failed);
end $$;

-- ---------------------------------------------------------------------
-- After the re-sync
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := (select id from public.organizations where name = 'Numbering Sdn Bhd');
  v_year text := to_char(current_date, 'YYYY');
  v_code text;
begin
  perform pg_temp.resync_contact_numbers();

  perform pg_temp.check_eq('the counter is moved past the codes in use',
    (select next_value from public.number_sequences
      where org_id = v_org and doc_type = 'contact'), 2);

  v_code := app.next_document_number_internal(v_org, 'contact');
  perform pg_temp.check_true('and the next number is free',
    v_code = 'C-' || v_year || '-00002');

  -- The insert that failed above now works.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, v_code, 'Kedai Runcit Aman', 'supplier');
  perform pg_temp.check_eq('so the contact is created',
    (select count(*) from public.contacts where org_id = v_org and code = v_code), 1);

  -- The `S-` code was 9, far ahead of the `C-` numbering. Had it been
  -- counted, the sequence would now be past 10.
  perform pg_temp.check_true('a different prefix did not drag the counter along',
    (select next_value from public.number_sequences
      where org_id = v_org and doc_type = 'contact') = 3);
end $$;

-- ---------------------------------------------------------------------
-- Forward only
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := (select id from public.organizations where name = 'Numbering Sdn Bhd');
  v_before bigint;
begin
  -- A counter already ahead of the table is correct: the codes in
  -- between may have been deleted, and handing them out again is what
  -- nobody wants.
  update public.number_sequences set next_value = 50
   where org_id = v_org and doc_type = 'contact';

  select next_value into v_before from public.number_sequences
   where org_id = v_org and doc_type = 'contact';

  perform pg_temp.resync_contact_numbers();

  perform pg_temp.check_eq('a counter ahead of the table is left alone',
    (select next_value from public.number_sequences
      where org_id = v_org and doc_type = 'contact'), v_before);
end $$;

-- ---------------------------------------------------------------------
-- Running it twice changes nothing the second time
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := (select id from public.organizations where name = 'Numbering Sdn Bhd');
  v_once bigint; v_twice bigint;
begin
  update public.number_sequences set next_value = 1
   where org_id = v_org and doc_type = 'contact';

  perform pg_temp.resync_contact_numbers();
  select next_value into v_once from public.number_sequences
   where org_id = v_org and doc_type = 'contact';

  perform pg_temp.resync_contact_numbers();
  select next_value into v_twice from public.number_sequences
   where org_id = v_org and doc_type = 'contact';

  perform pg_temp.check_eq('the re-sync is idempotent', v_twice, v_once);
end $$;

rollback;
