-- =====================================================================
-- iAkauntan :: the paper behind a posting is not a file to tidy
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/attachment_is_evidence.sql
--
-- `0708`. The delete button beside every attachment removed the object
-- and the row unconditionally, so the supplier's invoice a bill was read
-- off and then posted from went the same way as a photograph somebody
-- took twice.
--
-- What is asserted, and the last two are the ones a wider rule would
-- quietly break:
--
--   * a file behind a POSTED record cannot be deleted;
--   * nor can one a reading was built from, because those figures were
--     never keyed by anybody and the page is the only way to check them;
--   * a file nothing was built from CAN be deleted -- the whole point is
--     that "keep everything" is not the rule, "keep the evidence" is;
--   * and a company being deleted still cascades. A rule that refused
--     there would make an organization undeletable the moment one of its
--     bills was posted.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.a_file(
  p_org uuid, p_table text, p_id uuid, p_name text)
returns uuid language sql as $$
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size)
  values (p_org, p_table, p_id, p_name,
          format('%s/%s/%s/%s', p_org, p_table, p_id, p_name),
          'application/pdf', 90000)
  returning id;
$$;

do $$
declare
  v_org    uuid;
  v_sup    uuid;
  v_item   uuid;
  v_acct   uuid;
  v_tax    uuid;
  v_draft  uuid;
  v_posted uuid;
  v_spare  uuid;
  v_read   uuid;
  v_paper  uuid;
  v_n      integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Simpan Kertas Sdn Bhd');
  perform public.create_fiscal_year(v_org,
                                    date_trunc('year', current_date)::date);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Pembekal Sdn Bhd', 'supplier') returning id into v_sup;
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '5180', 'Belanja am', 'expense', 'operating_expense')
  returning id into v_acct;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price,
     purchase_account_id)
  values (v_org, 'ITM-1', 'Khidmat', 'service', false, 'C62', 100, v_acct)
  returning id into v_item;
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to)
  values (v_org, 'ST8', 'SST 8%', '01', 8, 'purchase') returning id into v_tax;

  -- ------------------------------------------------------------------
  -- A draft bill with a page nobody has done anything with.
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-EV-1', current_date, v_sup, 'MYR', 1, 'draft')
  returning id into v_draft;

  v_spare := pg_temp.a_file(v_org, 'purchase_documents', v_draft, 'dua.pdf');
  perform pg_temp.check_true('a page nobody built anything from is not '
    'evidence', not app.attachment_is_evidence(v_spare));

  delete from public.attachments where id = v_spare;
  select count(*) into v_n from public.attachments where id = v_spare;
  perform pg_temp.check_eq('and it can be deleted', v_n, 0);

  -- ------------------------------------------------------------------
  -- The same draft, with a page a reading FILLED IT IN from. `0707`
  -- writes `entry_source` exactly then.
  -- ------------------------------------------------------------------
  v_paper := pg_temp.a_file(v_org, 'purchase_documents', v_draft, 'bil.pdf');
  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     amount_charged, extracted)
  values (v_org, v_paper,
          format('%s/purchase_documents/%s/bil.pdf', v_org, v_draft),
          'claude', 'platform', 'ok', 0,
          jsonb_build_object('total_amount', 108))
  returning id into v_read;

  -- A reading that has filled nothing in yet leaves the page ordinary.
  perform pg_temp.check_true('a reading that filled nothing in does not '
    'lock the page', not app.attachment_is_evidence(v_paper));

  update public.purchase_documents set entry_source = 'ai_smartscan'
   where id = v_draft;
  perform pg_temp.check_true('once the reading filled the bill in, the '
    'page it was read off is evidence',
    app.attachment_is_evidence(v_paper));

  perform pg_temp.check_refused(
    'and it cannot be deleted',
    format('delete from public.attachments where id = %L', v_paper),
    '%never keyed by anybody%', '42501');

  -- A SECOND page filed against that same scanned bill, which nobody
  -- read. The bill says `ai_smartscan`, so a rule that asked only that
  -- would hold this page too -- and holding every photograph somebody
  -- ever files against a scanned bill is not the rule.
  v_spare := pg_temp.a_file(v_org, 'purchase_documents', v_draft, 'lima.pdf');
  perform pg_temp.check_true('a page nobody read, on a bill a reading '
    'filled in, is still ordinary',
    not app.attachment_is_evidence(v_spare));
  delete from public.attachments where id = v_spare;
  select count(*) into v_n from public.attachments where id = v_spare;
  perform pg_temp.check_eq('and it goes', v_n, 0);

  -- ------------------------------------------------------------------
  -- A reading that BECAME a record -- `ocr_scans.posted_id`, which
  -- `record_scan_posting` has written since `0694`. The record it
  -- became is neither posted nor tagged here, so this is the only
  -- branch that can answer.
  -- ------------------------------------------------------------------
  v_spare := pg_temp.a_file(v_org, 'contacts', v_sup, 'kepala-surat.pdf');
  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     amount_charged)
  values (v_org, v_spare,
          format('%s/contacts/%s/kepala-surat.pdf', v_org, v_sup),
          'claude', 'platform', 'ok', 0);
  perform pg_temp.check_true('before it is recorded as having become '
    'anything, a letterhead is ordinary',
    not app.attachment_is_evidence(v_spare));

  update public.ocr_scans
     set posted_table = 'contacts', posted_id = v_sup, posted_at = now()
   where attachment_id = v_spare;
  perform pg_temp.check_true('a reading that BECAME a record holds the '
    'page it was read off', app.attachment_is_evidence(v_spare));
  perform pg_temp.check_refused(
    'and that page cannot be deleted either',
    format('delete from public.attachments where id = %L', v_spare),
    '%stays with the record%', '42501');

  -- ------------------------------------------------------------------
  -- A posted bill, with a page nobody read at all.
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-EV-2', current_date, v_sup, 'MYR', 1, 'draft')
  returning id into v_posted;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_code_id, tax_rate)
  values (v_org, v_posted, 1, 'item', v_item, 'Khidmat', 1, 'C62', 100,
          v_tax, 8);

  v_spare := pg_temp.a_file(v_org, 'purchase_documents', v_posted, 'tiga.pdf');
  perform pg_temp.check_true('while it is a draft the page is ordinary',
    not app.attachment_is_evidence(v_spare));

  perform public.post_purchase_document(v_posted);
  perform pg_temp.check_true('once the bill is posted the page behind it '
    'is evidence', app.attachment_is_evidence(v_spare));
  perform pg_temp.check_refused(
    'and that one cannot be deleted either',
    format('delete from public.attachments where id = %L', v_spare),
    '%kept for seven years%', '42501');

  -- ------------------------------------------------------------------
  -- What the screen reads before it draws the button.
  -- ------------------------------------------------------------------
  -- A record with one of each, so "which files stay" is a question the
  -- list has to answer rather than a count it can get right by saying
  -- everything.
  perform pg_temp.a_file(v_org, 'purchase_documents', v_draft, 'enam.pdf');

  select count(*) into v_n
    from public.attachments_of(v_org, 'purchase_documents', v_draft);
  perform pg_temp.check_eq('the list has both files', v_n, 2);

  select count(*) into v_n
    from public.attachments_of(v_org, 'purchase_documents', v_draft)
   where is_evidence;
  perform pg_temp.check_eq('and says one of them stays', v_n, 1);

  select count(*) into v_n
    from public.attachments_of(v_org, 'purchase_documents', v_draft)
   where is_evidence and file_name = 'bil.pdf';
  perform pg_temp.check_eq('and which one it is', v_n, 1);

  select count(*) into v_n
    from public.attachments_of(v_org, 'purchase_documents',
                               gen_random_uuid());
  perform pg_temp.check_eq('a record with no paperwork lists nothing',
    v_n, 0);

  -- ------------------------------------------------------------------
  -- And the DRAFT itself can still be thrown away
  --
  -- `scan_inbox.sql` caught this: deleting a draft cascades through
  -- `app.delete_attachments_of_row` to its files, and a rule that
  -- refused there would make a bill somebody scanned and then thought
  -- better of impossible to delete -- with a message about seven years
  -- of record keeping, about a document that was never a record of
  -- anything. A file is evidence OF something; when the record is
  -- gone, it is evidence of nothing.
  -- ------------------------------------------------------------------
  -- With the reading recorded as having BECOME this bill, which is the
  -- branch that does not consult the record at all. Without the
  -- existence check that branch answers "evidence" about a bill that no
  -- longer exists, and the delete is refused.
  update public.ocr_scans
     set posted_table = 'purchase_documents', posted_id = v_draft,
         posted_at = now()
   where id = v_read;
  perform pg_temp.check_true('while the bill is there its page is held',
    app.attachment_is_evidence(v_paper));

  delete from public.purchase_documents where id = v_draft;
  select count(*) into v_n
    from public.attachments where entity_id = v_draft;
  perform pg_temp.check_eq('a draft nobody wants takes its paper with it',
    v_n, 0);

  raise notice 'attachments: the evidence stays, the spare copy goes';
end $$;

-- ---------------------------------------------------------------------
-- And a company can still be deleted
--
-- EQUIVALENT MUTANT, written down rather than left as a survivor:
-- removing the "the organization is already gone" escape from
-- `app.refuse_deleting_evidence` does not fail this, and the reason is
-- the cascade ORDER. Deleting an organization deletes its purchase
-- documents, whose own `attachments_follow_the_record` trigger clears
-- their files -- and by then the attachment's `entity_id` resolves to
-- no record at all, so `attachment_is_evidence` answers false and the
-- delete is allowed whether the escape is there or not.
--
-- The escape stays. It costs one index lookup and it is the difference
-- between "today's cascade order happens to reach the rows in a
-- forgiving sequence" and "a cascade is not somebody tidying a file",
-- which is the rule actually meant. What follows asserts the outcome.
--
-- Outside the block above because it needs the rows to be real and then
-- gone. A rule that refused here would make an organization undeletable
-- the moment one of its bills was posted -- and `0708`'s refusal is
-- about somebody tidying a file, not about a cascade.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_sup   uuid;
  v_bill  uuid;
  v_file  uuid;
  v_n     integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Syarikat Tutup Sdn Bhd');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Pembekal', 'supplier') returning id into v_sup;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-EV-3', current_date, v_sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  v_file := pg_temp.a_file(v_org, 'purchase_documents', v_bill, 'empat.pdf');
  update public.purchase_documents set entry_source = 'ai_smartscan'
   where id = v_bill;
  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     amount_charged)
  values (v_org, v_file,
          format('%s/purchase_documents/%s/empat.pdf', v_org, v_bill),
          'claude', 'platform', 'ok', 0);

  perform pg_temp.check_true('the file is evidence',
    app.attachment_is_evidence(v_file));

  delete from public.organizations where id = v_org;
  select count(*) into v_n from public.attachments where id = v_file;
  perform pg_temp.check_eq('and the company can still be deleted', v_n, 0);

  raise notice 'attachments: a cascade is not somebody tidying a file';
end $$;

rollback;
