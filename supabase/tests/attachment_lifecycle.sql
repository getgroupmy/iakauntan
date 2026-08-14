-- =====================================================================
-- iAkauntan :: an attachment does not outlive its record
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/attachment_lifecycle.sql
--
-- Deleting a draft bill used to leave its attachment row behind,
-- pointing at nothing. Invisible in the app, because every screen
-- reaches an attachment through its parent — so it is not a bug anybody
-- reports, only one somebody finds later wondering what a storage bill
-- is for.
--
-- A foreign key cannot say this: `attachments` is polymorphic, and a
-- foreign key needs one parent named at definition time. 0126 says it
-- with a trigger instead, and this is what holds the trigger to the
-- promise a foreign key would have made.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The receipt goes when the bill goes
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Lampiran Sdn Bhd');
  v_supplier uuid;
  v_bill uuid;
  v_other uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-001', 'Pembekal', 'supplier') returning id into v_supplier;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status, total_amount)
  values (v_org, 'bill', 'BILL-TEST-1', v_supplier, current_date, 'draft', 0)
  returning id into v_bill;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status, total_amount)
  values (v_org, 'bill', 'BILL-TEST-2', v_supplier, current_date, 'draft', 0)
  returning id into v_other;

  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path)
  values
    (v_org, 'purchase_documents', v_bill, 'a.pdf',
     v_org || '/purchase_documents/' || v_bill || '/a.pdf'),
    (v_org, 'purchase_documents', v_bill, 'b.pdf',
     v_org || '/purchase_documents/' || v_bill || '/b.pdf'),
    (v_org, 'purchase_documents', v_other, 'c.pdf',
     v_org || '/purchase_documents/' || v_other || '/c.pdf');

  perform pg_temp.check_eq('the bill starts with two receipts',
    (select count(*) from public.attachments
      where entity_table = 'purchase_documents' and entity_id = v_bill), 2);

  delete from public.purchase_documents where id = v_bill;

  perform pg_temp.check_eq('deleting it takes both with it',
    (select count(*) from public.attachments
      where entity_table = 'purchase_documents' and entity_id = v_bill), 0);

  -- The half that makes the above mean something. A trigger deleting
  -- everything would pass the assertion above and be catastrophic.
  perform pg_temp.check_eq('and leaves the other bill''s alone',
    (select count(*) from public.attachments
      where entity_table = 'purchase_documents' and entity_id = v_other), 1);
end $$;

-- ---------------------------------------------------------------------
-- A claim's receipt too, which is the one an employee uploaded
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Tuntutan Sdn Bhd');
  v_user uuid := pg_temp.another_user('staff@tuntutan.test');
  v_employee uuid;
  v_claim uuid;
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_user, 'employee') on conflict do nothing;
  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date)
  values (v_org, 'E-1', 'Staff', v_user, current_date)
  returning id into v_employee;

  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount)
  values (v_org, 'CLM-T-1', v_employee, current_date, 'Parking', 'draft', 12)
  returning id into v_claim;

  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path)
  values (v_org, 'expense_claims', v_claim, 'receipt.jpg',
          v_org || '/expense_claims/' || v_claim || '/receipt.jpg');

  delete from public.expense_claims where id = v_claim;

  perform pg_temp.check_eq('a deleted claim takes its receipt with it',
    (select count(*) from public.attachments
      where entity_table = 'expense_claims' and entity_id = v_claim), 0);
end $$;

-- ---------------------------------------------------------------------
-- Nothing is stranded now, and nothing can be stranded later
-- ---------------------------------------------------------------------
do $$
declare
  v_entity text;
  v_orphans int;
  v_missing text;
begin
  -- Every parent an attachment actually points at carries the trigger.
  -- Attaching to something new without one is how the next pile starts,
  -- and it would otherwise say nothing at all.
  select string_agg(distinct a.entity_table, ', ') into v_missing
    from public.attachments a
   where not exists (
     select 1 from pg_trigger t
      where t.tgrelid = to_regclass('public.' || a.entity_table)
        and t.tgname = 'attachments_follow_the_record'
        and not t.tgisinternal);

  if v_missing is not null then
    raise exception
      'FAIL attachments hang off a table with no cleanup trigger: %',
      v_missing;
  end if;
  raise notice 'ok   every table attachments point at cleans up after itself';

  -- And there are none left over from before the trigger existed.
  for v_entity in select distinct entity_table from public.attachments
  loop
    if to_regclass('public.' || v_entity) is null then
      raise exception 'FAIL attachments point at a table that does not exist: %',
        v_entity;
    end if;
    execute format(
      'select count(*) from public.attachments a
        where a.entity_table = %L
          and not exists (select 1 from public.%I p where p.id = a.entity_id)',
      v_entity, v_entity) into v_orphans;
    perform pg_temp.check_eq(
      format('no %s attachment is orphaned', v_entity), v_orphans, 0);
  end loop;
end $$;

rollback;
