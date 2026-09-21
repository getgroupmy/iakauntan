-- =====================================================================
-- iAkauntan :: a note is as private as what it is about
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/notes.sql
--
-- `public.notes` has existed since `0008` -- free-form notes filed
-- against any row, on the `entity_table`/`entity_id` shape
-- `attachments` uses -- with four policies, a grant and an index, and
-- nothing anywhere has ever touched it. The orphan sweep found
-- `notes.is_pinned` and the table was the finding.
--
-- `0644` replaced the policies before anything is built on them. They
-- were the naive version: `is_org_member` to read, `can_write` to
-- write, edit or delete ANY note. Filed against an
-- `employee_documents` row that made a note about somebody's passport
-- company reading, which is the exact hole
-- `app.can_read_attachment` exists to close for the file itself.
--
-- Nothing was lost -- the table is empty everywhere, because nothing
-- could write to it. This is the door being shut before there is
-- anything behind it, and these are the assertions that say it is.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_owner  uuid := pg_temp.test_user();
  v_org    uuid := pg_temp.test_org('Nota Sdn Bhd');
  v_clerk  uuid;
  v_hr     uuid;
  v_them   uuid;
  v_person uuid;
  v_doc    uuid;
  v_note   uuid;
  v_took   boolean;
  v_seen   integer;
begin
  v_clerk := pg_temp.another_user('akaun@nota.test');
  v_hr    := pg_temp.another_user('hr@nota.test');
  v_them  := pg_temp.another_user('pekerja@nota.test');

  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'accounts_clerk'),
         (v_org, v_hr, 'hr_manager'),
         (v_org, v_them, 'employee')
  on conflict do nothing;

  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date)
  values (v_org, 'E-001', 'Pekerja', v_them, current_date)
  returning id into v_person;

  insert into public.employee_documents
    (org_id, employee_id, title, doc_type, expires_date)
  values (v_org, v_person, 'Passport', 'identity', current_date + 90)
  returning id into v_doc;

  -- ------------------------------------------------------------------
  -- HR writes the note
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_hr);
  set local role authenticated;
  insert into public.notes (org_id, entity_table, entity_id, content)
  values (v_org, 'employee_documents', v_doc,
          'Passport expires in March, chase the renewal')
  returning id into v_note;
  reset role;

  perform pg_temp.check_true('HR may file a note on a personnel record',
    v_note is not null);

  -- Recorded rather than claimed. `created_by` had never been written
  -- by anything either.
  perform pg_temp.check_eq('and it records who wrote it',
    (select created_by from public.notes where id = v_note), v_hr);

  -- From the SESSION, not from the payload. A client that sends
  -- `created_by` is a client claiming to be somebody else, and a
  -- `coalesce(new.created_by, auth.uid())` would believe it -- a note
  -- in a colleague's name, which is the forgery the whole authorship
  -- rule exists to stop. That mutant survived until this went in.
  declare v_forged uuid;
  begin
    set local role authenticated;
    insert into public.notes
      (org_id, entity_table, entity_id, content, created_by)
    values (v_org, 'employee_documents', v_doc,
            'Signed by somebody who did not write it', v_them)
    returning id into v_forged;
    reset role;

    perform pg_temp.check_eq(
      'and a client cannot sign a note in somebody else''s name',
      (select created_by from public.notes where id = v_forged), v_hr);
  end;

  -- ------------------------------------------------------------------
  -- The clerk, who is the whole point
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_clerk);

  perform pg_temp.check_true('a clerk can write the ledger',
    app.can_write(v_org) or app.can_read_ledger(v_org));
  perform pg_temp.check_true('and is not HR', not app.can_manage_hr(v_org));
  perform pg_temp.check_true('nor runs payroll',
    not app.can_run_payroll(v_org));
  perform pg_temp.check_true('nor an administrator', not app.can_admin(v_org));

  -- The old policy was `is_org_member`, and the clerk is one.
  perform pg_temp.check_true('the clerk IS a member of the company',
    app.is_org_member(v_org));

  set local role authenticated;
  select count(*)::int into v_seen from public.notes where id = v_note;
  reset role;
  perform pg_temp.check_eq(
    'and still cannot read a note about a passport', v_seen, 0);

  -- The control: a note on something the ledger audience does own.
  -- Without it, a refusal for any reason reads as the carve-out
  -- working.
  declare v_contact uuid; v_ledger_note uuid;
  begin
    perform pg_temp.sign_in_as(v_owner);
    insert into public.contacts (org_id, code, name, contact_type)
    values (v_org, 'C-001', 'Pelanggan', 'customer') returning id into v_contact;

    perform pg_temp.sign_in_as(v_clerk);
    set local role authenticated;
    insert into public.notes (org_id, entity_table, entity_id, content)
    values (v_org, 'contacts', v_contact, 'Promised payment Friday')
    returning id into v_ledger_note;
    select count(*)::int into v_seen from public.notes where id = v_ledger_note;
    reset role;

    perform pg_temp.check_true('while a note on a customer is theirs to file',
      v_ledger_note is not null);
    perform pg_temp.check_eq('and theirs to read', v_seen, 1);
  end;

  -- ------------------------------------------------------------------
  -- Whose words they are
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_hr);
  set local role authenticated;
  select count(*)::int into v_seen from public.notes where id = v_note;
  reset role;
  perform pg_temp.check_eq('HR reads the note it wrote', v_seen, 1);

  -- The employee the passport belongs to reads it too: the same
  -- question the document asks, and `can_read_attachment` lets them
  -- read their own.
  perform pg_temp.sign_in_as(v_them);
  set local role authenticated;
  select count(*)::int into v_seen from public.notes where id = v_note;
  reset role;
  perform pg_temp.check_eq('so does the person it is about', v_seen, 1);

  -- And may not rewrite what HR said about them.
  set local role authenticated;
  update public.notes set content = 'Nothing to chase' where id = v_note;
  get diagnostics v_seen = row_count;
  reset role;
  perform pg_temp.check_eq(
    'but cannot rewrite what somebody else wrote', v_seen, 0);
  perform pg_temp.check_eq('so the words are still HR''s',
    (select content from public.notes where id = v_note),
    'Passport expires in March, chase the renewal');

  -- The author may correct their own.
  perform pg_temp.sign_in_as(v_hr);
  set local role authenticated;
  update public.notes set content = 'Passport expires in March; renewal filed'
   where id = v_note;
  get diagnostics v_seen = row_count;
  reset role;
  perform pg_temp.check_eq('the author may correct their own', v_seen, 1);

  -- And an edit cannot reassign it. Without the trigger holding
  -- `created_by`, a correction could put the note in somebody else's
  -- name -- the same forgery by a longer route.
  set local role authenticated;
  update public.notes set created_by = v_them where id = v_note;
  reset role;
  perform pg_temp.check_eq('and cannot hand it to somebody else',
    (select created_by from public.notes where id = v_note), v_hr);

  -- ------------------------------------------------------------------
  -- Deleting, which is not editing
  -- ------------------------------------------------------------------
  -- An administrator may take a note off a file -- housekeeping
  -- somebody may legitimately need to do -- and may NOT edit it,
  -- because that is words in a colleague's mouth under their name.
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('the owner administers the company',
    app.can_admin(v_org));

  set local role authenticated;
  update public.notes set content = 'Rewritten by the boss' where id = v_note;
  get diagnostics v_seen = row_count;
  reset role;
  perform pg_temp.check_eq(
    'an administrator may not rewrite somebody else''s note', v_seen, 0);

  set local role authenticated;
  delete from public.notes where id = v_note;
  get diagnostics v_seen = row_count;
  reset role;
  perform pg_temp.check_eq('but may remove it', v_seen, 1);

  perform pg_temp.sign_out();
end $$;

rollback;
