-- =====================================================================
-- iAkauntan :: where the paper ended up
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/scan_inbox.sql
--
-- `0694`. `ocr_scans` recorded what was read, what it cost and which
-- provider answered, and never recorded what the photograph BECAME. So
-- a scan that quietly produced nothing looked exactly like one that
-- posted a bill, and "I scanned that receipt, where is it?" had no
-- answer anywhere in the product.
--
-- What has to be true:
--
--   * THE DESTINATION IS READ OFF THE ATTACHMENT. A caller-supplied
--     table could differ from where the FILE is filed, and then the
--     inbox names a document the picture is not attached to. This is
--     the assertion the whole design turns on.
--   * IT RESOLVES TO SOMETHING A PERSON RECOGNISES. A table name and a
--     uuid is not an answer; `PB-1041` is.
--   * A DELETED DOCUMENT STILL SHOWS, with no label. "This became a
--     bill that no longer exists" is the answer; a row that vanished
--     would read as a scan that never happened. Deleting a document
--     also deletes its ATTACHMENT, so the row has to survive losing
--     the thing its file name comes off -- which is why the name falls
--     back to the storage object.
--   * ONE COMPANY'S PAPER ONLY. The inbox takes an org id and the
--     function is SECURITY DEFINER, so RLS is not doing this.
--   * THE REFERENCE REACHES THE SCREEN. `0680` mints one for a failed
--     scan and tells the person to quote it; until `0695` it was on
--     the row and nowhere a person could read it.
--   * AND THE GUARD IS WHAT REFUSES, not the check constraint behind
--     it. Both raise `23514`, so asserting the code alone passes with
--     the guard gone -- a mutant proved exactly that.
--   * AND AN EXPLICIT TABLE IS CHECKED. `bank_transactions` needs one,
--     because a statement becomes forty rows and has no single record
--     to be read off the attachment -- so the parameter exists, and it
--     must not accept a typed string.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A capture, parked against a table, and the reading of it.
create or replace function pg_temp.a_scan(
  p_org uuid, p_table text, p_id uuid, p_file text,
  p_kind text default null)
returns uuid language plpgsql as $$
declare v_att uuid;
begin
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path)
  values (p_org, p_table, p_id, p_file,
          p_org || '/' || p_table || '/' || p_id || '/' || p_file)
  returning id into v_att;

  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     extracted, document_kind)
  values (p_org, v_att, p_org || '/' || p_table || '/' || p_id || '/'
          || p_file, 'gemini', 'platform', 'ok',
          jsonb_build_object('target', 'purchases.bill'), p_kind);
  return v_att;
end;
$$;

do $$
declare
  v_owner  uuid := pg_temp.test_user();
  v_org    uuid;
  v_supp   uuid;
  v_bill   uuid;
  v_gone   uuid;
  v_att    uuid;
  v_att2   uuid;
  v_scan   uuid;
  v_label  text;
  v_table  text;
  v_n      integer;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Kertas Sdn Bhd');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SP1', 'Pejabat Tanah', 'supplier') returning id into v_supp;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status, total_amount)
  values (v_org, 'bill', 'PB-1041', v_supp, app.today(), 'draft', 50)
  returning id into v_bill;

  -- -----------------------------------------------------------------
  -- 1. Nothing came of it yet
  -- -----------------------------------------------------------------
  v_att := pg_temp.a_scan(v_org, 'purchase_documents', v_bill,
                          'receipt.jpg', 'bill');

  select posted_table into v_table from public.scan_inbox(v_org)
   where attachment_id = v_att;
  if v_table is not null then
    raise exception 'a scan nobody posted claims to have become %', v_table;
  end if;

  -- It is still in the list. A reading that produced nothing is the
  -- most interesting row in an inbox, not one to hide.
  select count(*) into v_n from public.scan_inbox(v_org)
   where attachment_id = v_att;
  if v_n <> 1 then
    raise exception 'an unposted scan is not in the inbox';
  end if;

  -- -----------------------------------------------------------------
  -- 2. Recorded from the attachment, and resolved to a number
  -- -----------------------------------------------------------------
  v_scan := public.record_scan_posting(v_org, v_att);
  if v_scan is null then
    raise exception 'nothing was written on the scan';
  end if;

  select posted_table, posted_label into v_table, v_label
    from public.scan_inbox(v_org) where attachment_id = v_att;
  if v_table is distinct from 'purchase_documents' then
    raise exception 'the scan landed in % rather than purchase_documents',
      v_table;
  end if;
  if v_label is distinct from 'PB-1041' then
    raise exception 'the inbox says % rather than PB-1041', v_label;
  end if;

  -- The date too, because "which one was it" is a number and a day.
  select posted_date into v_label from public.scan_inbox(v_org)
   where attachment_id = v_att;
  if v_label is null then
    raise exception 'the inbox gave no date for a posted bill';
  end if;

  -- -----------------------------------------------------------------
  -- 3. It follows the FILE, not a caller's opinion
  --
  -- The point of reading the destination off the attachment. Refile the
  -- picture onto another bill and record again: the inbox has to name
  -- the bill the picture is actually filed against.
  -- -----------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status, total_amount)
  values (v_org, 'bill', 'PB-2000', v_supp, app.today(), 'draft', 50)
  returning id into v_gone;

  update public.attachments
     set entity_id = v_gone,
         storage_path = v_org || '/purchase_documents/' || v_gone
                        || '/receipt.jpg'
   where id = v_att;
  perform public.record_scan_posting(v_org, v_att);

  select posted_label into v_label from public.scan_inbox(v_org)
   where attachment_id = v_att;
  if v_label is distinct from 'PB-2000' then
    raise exception
      'the inbox says % after the file moved to PB-2000', v_label;
  end if;

  -- -----------------------------------------------------------------
  -- 4. A document deleted afterwards
  -- -----------------------------------------------------------------
  -- And this takes the PICTURE with it: `delete_attachments_of_row`
  -- deletes the attachment, and `ocr_scans.attachment_id` is `on
  -- delete set null`. So the scan is orphaned rather than removed, and
  -- the inbox has to stay readable through that -- which is the case
  -- that made the file name fall back to the storage path.
  delete from public.purchase_documents where id = v_gone;

  select count(*) into v_n from public.scan_inbox(v_org)
   where scan_id = v_scan;
  if v_n <> 1 then
    raise exception 'the scan vanished when its bill was deleted';
  end if;

  select posted_label into v_label from public.scan_inbox(v_org)
   where scan_id = v_scan;
  if v_label is not null then
    raise exception 'a deleted bill still labels the scan as %', v_label;
  end if;

  -- Still nameable. The attachment is gone, so `file_name` is null and
  -- the object's own path is what is left of it.
  select file_name into v_label from public.scan_inbox(v_org)
   where scan_id = v_scan;
  if v_label is distinct from 'receipt.jpg' then
    raise exception
      'an orphaned scan is named % rather than receipt.jpg', v_label;
  end if;

  -- And it still says it became a purchase document, which is the
  -- only remaining trace of where the paper went.
  select posted_table into v_table from public.scan_inbox(v_org)
   where scan_id = v_scan;
  if v_table is distinct from 'purchase_documents' then
    raise exception 'an orphaned scan forgot its destination';
  end if;

  -- -----------------------------------------------------------------
  -- 5. The explicit table, for the one thing that becomes many rows
  -- -----------------------------------------------------------------
  v_att2 := pg_temp.a_scan(v_org, 'bank_transactions', v_bill,
                           'statement.jpg', 'bank_statement');
  perform public.record_scan_posting(
    v_org, v_att2, 'bank_transactions', v_bill);

  select posted_table, posted_label into v_table, v_label
    from public.scan_inbox(v_org) where attachment_id = v_att2;
  if v_table is distinct from 'bank_transactions' then
    raise exception 'the statement landed in %', v_table;
  end if;
  if v_label is distinct from 'Statement lines' then
    raise exception 'a statement is labelled %', v_label;
  end if;

  -- And a table nothing scans into is refused, or the column fills up
  -- with whatever a caller typed.
  begin
    perform public.record_scan_posting(v_org, v_att2, 'payroll_runs', v_bill);
    raise exception 'a posting was recorded into payroll_runs';
  exception
    when sqlstate 'P0002' then null;
  end;

  -- An explicit table with no record id names nothing.
  --
  -- The MESSAGE, not just the code. `ocr_scans_posted_together` would
  -- refuse this too and raise `23514` doing it, so a test that checked
  -- only the code passes with the guard deleted -- which a mutant
  -- proved. The constraint is the backstop; the guard is what gives a
  -- caller a sentence they can act on.
  begin
    perform public.record_scan_posting(
      v_org, v_att2, 'bank_transactions', null);
    raise exception 'a posting was recorded with no record';
  exception
    when sqlstate '23514' then
      if sqlerrm not like '%needs the record it posted to%' then
        raise exception
          'the constraint refused it rather than the guard: %', sqlerrm;
      end if;
  end;

  -- -----------------------------------------------------------------
  -- 6. The filter, which is what an inbox is for
  -- -----------------------------------------------------------------
  select count(*) into v_n
    from public.scan_inbox(v_org, 100, 'unposted');
  if v_n <> 0 then
    raise exception '% scans read as unposted, wanted 0', v_n;
  end if;
  select count(*) into v_n from public.scan_inbox(v_org, 100, 'posted');
  if v_n <> 2 then
    raise exception '% scans read as posted, wanted 2', v_n;
  end if;

  -- -----------------------------------------------------------------
  -- 7. The reference a failed scan was given
  --
  -- `0680` mints it, writes it on the row, and tells the person to
  -- quote it. `0695` is it reaching the screen: until then the one
  -- identifier the arrangement exists to hand over was readable only
  -- by somebody with SQL, which is the trip `0680` was written to
  -- save.
  -- -----------------------------------------------------------------
  insert into public.ocr_scans
    (org_id, storage_path, provider, key_source, status, error, log_ref)
  values (v_org, v_org || '/expenses/x/broken.jpg', 'gemini', 'platform',
          'failed', 'The reader refused the document: HTTP 503',
          'ocr.failed-7f3a')
  returning id into v_scan;

  select log_ref into v_label from public.scan_inbox(v_org)
   where scan_id = v_scan;
  if v_label is distinct from 'ocr.failed-7f3a' then
    raise exception 'the inbox gave the reference as %', v_label;
  end if;

  -- And a scan that did not fail has none, rather than an empty string
  -- somebody would try to quote.
  select log_ref into v_label from public.scan_inbox(v_org)
   where attachment_id = v_att2;
  if v_label is not null then
    raise exception 'a scan that worked carries the reference %', v_label;
  end if;

  -- The file name, because that is what the list shows first and it
  -- lives on the attachment rather than on the scan.
  select file_name into v_label from public.scan_inbox(v_org)
   where attachment_id = v_att2;
  if v_label is distinct from 'statement.jpg' then
    raise exception 'the inbox names the file %', v_label;
  end if;

  raise notice 'scan inbox: every sheet says what it became';
end $$;

-- ---------------------------------------------------------------------
-- One company's paper
--
-- `scan_inbox` is SECURITY DEFINER and takes an org id, so RLS is not
-- doing this and the guard inside it is the only thing that is.
-- ---------------------------------------------------------------------
do $$
declare
  v_mine   uuid;
  v_theirs uuid;
  v_supp   uuid;
  v_bill   uuid;
  v_n      integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_mine   := pg_temp.test_org('Kertas Satu');
  v_theirs := pg_temp.test_org('Kertas Dua');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_theirs, 'SP9', 'Theirs', 'supplier') returning id into v_supp;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status, total_amount)
  values (v_theirs, 'bill', 'PB-9', v_supp, app.today(), 'draft', 10)
  returning id into v_bill;
  perform pg_temp.a_scan(v_theirs, 'purchase_documents', v_bill, 'x.jpg');

  select count(*) into v_n from public.scan_inbox(v_theirs);
  if v_n <> 1 then
    raise exception 'the owner cannot see their own scan';
  end if;

  -- Now as somebody who is not in that company at all. `test_user()`
  -- is MEMOIZED -- it answers with the one fixture account every time
  -- -- so signing in as it again is signing in as the owner, and the
  -- assertion would pass while proving nothing. `another_user` is the
  -- one that makes a second person.
  perform pg_temp.sign_in_as(pg_temp.another_user('stranger@iakauntan.test'));
  select count(*) into v_n from public.scan_inbox(v_theirs);
  if v_n <> 0 then
    raise exception 'a stranger read % of another company''s scans', v_n;
  end if;

  raise notice 'scan inbox: a stranger sees none of it';
end $$;

rollback;
