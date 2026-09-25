-- =====================================================================
-- iAkauntan :: 0714 a file kept for later
--
-- Asked for as "add an upload button where this button will upload file
-- to storage and save it for later use".
--
-- ---------------------------------------------------------------------
-- Uploading was never the hard part
--
-- `uploadAttachment` has put files in the bucket since `0010`. What
-- there has never been is a way to put one there WITHOUT sending it to
-- a reader -- every door into AI SmartScan runs `captureAndRead`, which
-- uploads and then spends money on a model in the same breath. Somebody
-- with a month of statements to file cannot simply put them somewhere
-- safe and come back on Tuesday.
--
-- And a file uploaded with no reading is INVISIBLE. `scan_inbox` --
-- the list behind the AI SmartScan screen -- selects `from
-- public.ocr_scans`, so a file that was never read has no row in it and
-- appears nowhere in the product at all. "Saved for later use" that
-- nobody can find again is not saved; it is lost with extra steps.
--
-- ---------------------------------------------------------------------
-- Why not a row in `ocr_scans`
--
-- That was the first idea and it is wrong twice over.
--
-- `ocr_scans.provider` and `key_source` are NOT NULL, and the table's
-- own comment says what it is for: *"Kept whether it worked or not,
-- because 'why was I charged' and 'why did nothing come back' are the
-- same question asked twice."* A row there for a document no reader
-- ever saw would have to invent a provider, and it would be an answer
-- to a question about charging that describes something never charged
-- for.
--
-- `status` is checked against `('pending', 'ok', 'failed')`, and none of
-- the three is true of a file nobody asked to read. `failed` is the
-- tempting one and it is a lie: nothing failed.
--
-- So the fact lives on the ATTACHMENT, which is the thing that actually
-- exists, and the inbox reaches for it.
--
-- ---------------------------------------------------------------------
-- `kept_at`, and why a timestamp rather than a flag
--
-- A boolean would answer "is this one of those" and nothing else. The
-- question a person actually asks of a pile is *when did I put this
-- here*, and the inbox is ordered by time -- a kept file has to sort
-- among the scans, and `scanned_at` is what it sorts by. A flag would
-- need the upload's own `created_at` alongside it to do the same job,
-- and `attachments` has no such column.
--
-- Nullable and null everywhere else, so an attachment on a bill is
-- untouched and nothing about the existing lists moves.
--
-- ---------------------------------------------------------------------
-- The inbox is the pile of paper, so it unions
--
-- `smartscan_screen.dart` opens with "the pile of paper, and what each
-- sheet became". It has a chip that says **Everything**. A file kept
-- and not read is part of that pile, and a chip called Everything that
-- omitted it would be the third time in this file that a thing is
-- filed where a person cannot see it.
--
-- `scan_id` therefore comes back NULL for these rows, and that is the
-- honest answer: there is no scan. The screen reads it as "kept, not
-- read yet" and the detail sheet offers to read it -- which is the
-- "later use" the button is named for.
--
-- A kept file that HAS since been read drops out of the union, because
-- its `ocr_scans` row is the better record of it and showing both would
-- list one sheet of paper twice.
-- =====================================================================

alter table public.attachments
  add column if not exists kept_at timestamptz;

comment on column public.attachments.kept_at is
  'When somebody uploaded this to KEEP rather than to read. Null on '
  'every attachment that arrived any other way -- filed against a bill, '
  'a receipt, an e-Invoice. `scan_inbox` unions these in so that a file '
  'put somewhere safe can be found again, which is the whole of what '
  'the upload button promises. A timestamp rather than a flag because '
  'the inbox sorts by time and this is the only time there is. 0714.';

-- Only the kept ones, which are a handful beside every attachment in
-- the system. `where kept_at is not null` keeps the index the size of
-- the thing it is for.
create index if not exists attachments_kept_idx
  on public.attachments (org_id, kept_at desc)
  where kept_at is not null;

create or replace function public.scan_inbox(
  p_org_id uuid,
  p_limit integer default 100,
  p_only text default 'all')
returns table (
  scan_id       uuid,
  attachment_id uuid,
  file_name     text,
  storage_path  text,
  -- `0698`. What KIND of file it is, so the screen offering to read
  -- it again can leave out the readers that cannot open it -- which
  -- for a PDF is most of them. Off the attachment, because the scan
  -- row never recorded it.
  mime_type     text,
  scanned_at    timestamptz,
  provider      text,
  status        text,
  error         text,
  log_ref       text,
  document_kind text,
  kind_label    text,
  target        text,
  posted_table  text,
  posted_id     uuid,
  posted_at     timestamptz,
  posted_label  text,
  posted_date   date,
  reviewed_at   timestamptz,
  corrected     boolean)
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  select s.id,
         s.attachment_id,
         -- The attachment's name, falling back to the object's. A
         -- document deleted later takes its attachment with it --
         -- `delete_attachments_of_row` -- and `ocr_scans.attachment_id`
         -- is `on delete set null`, so the scan survives with nothing
         -- to name it. `storage_path` is on the SCAN, so the last
         -- segment is still the file somebody photographed.
         coalesce(a.file_name,
                  nullif(split_part(s.storage_path, '/', -1), '')),
         -- The LIVE key, not the one the reader was handed. `0697`.
         -- `refileAttachment` moves the object onto the record once
         -- that record exists and updates the ATTACHMENT's path; the
         -- scan keeps the placeholder key it was read under. So the
         -- scan's own path is a historical note, and opening it 404s
         -- for every scan that became something -- which was every
         -- scan that worked.
         coalesce(a.storage_path, s.storage_path),
         a.mime_type,
         s.created_at,
         s.provider,
         s.status,
         s.error,
         s.log_ref,
         s.document_kind,
         k.label,
         s.extracted ->> 'target',
         s.posted_table,
         s.posted_id,
         s.posted_at,
         -- One left join per destination, and a null label where the
         -- record has since been deleted: "this became a bill that no
         -- longer exists" is the answer, and dropping the row would
         -- read as a scan that never happened.
         case s.posted_table
           when 'sales_documents'    then sd.doc_no
           when 'purchase_documents' then pd.doc_no
           when 'expenses'           then e.expense_no
           when 'contacts'           then c.name
           when 'bank_transactions'  then 'Statement lines'
           else null
         end,
         case s.posted_table
           when 'sales_documents'    then sd.doc_date
           when 'purchase_documents' then pd.doc_date
           when 'expenses'           then e.expense_date
           else null
         end,
         s.reviewed_at,
         s.corrected is not null
    from public.ocr_scans s
    left join public.attachments a on a.id = s.attachment_id
    left join public.scan_document_kinds k on k.code = s.document_kind
    left join public.sales_documents sd
           on s.posted_table = 'sales_documents' and sd.id = s.posted_id
    left join public.purchase_documents pd
           on s.posted_table = 'purchase_documents' and pd.id = s.posted_id
    left join public.expenses e
           on s.posted_table = 'expenses' and e.id = s.posted_id
    left join public.contacts c
           on s.posted_table = 'contacts' and c.id = s.posted_id
   where s.org_id = p_org_id
     and app.is_org_member(p_org_id)
     and case p_only
           when 'posted'   then s.posted_table is not null
           when 'unposted' then s.posted_table is null
           else true
         end
   union all

  -- A file kept and not read. `0714`.
  --
  -- Every column the scan half fills from `ocr_scans` is NULL here, and
  -- deliberately: there is no scan, no provider, no status and nothing
  -- was charged. `scanned_at` is `kept_at`, so it sorts into the pile
  -- at the moment somebody put it there.
  select null::uuid,
         a.id,
         a.file_name,
         a.storage_path,
         a.mime_type,
         a.kept_at,
         null::text, null::text, null::text, null::text, null::text,
         null::text, null::text,
         null::text, null::uuid, null::timestamptz, null::text,
         null::date,
         null::timestamptz,
         false
    from public.attachments a
   where a.org_id = p_org_id
     and a.kept_at is not null
     and app.is_org_member(p_org_id)
     -- Read since, and the scan row is the better record of it. Both
     -- would put one sheet of paper in the list twice.
     and not exists (select 1 from public.ocr_scans s2
                      where s2.attachment_id = a.id)
     -- A kept file has become nothing by definition, so it belongs
     -- under `unposted` and never under `posted`.
     and p_only is distinct from 'posted'

   order by 6 desc
   limit greatest(1, least(coalesce(p_limit, 100), 500));
$$;
revoke all on function public.scan_inbox(uuid, integer, text)
  from public, anon;
grant execute on function public.scan_inbox(uuid, integer, text)
  to authenticated;

comment on function public.scan_inbox(uuid, integer, text) is
  'The pile of paper: every reading, and every file kept without one. '
  '`scan_id` is null on the second kind, because there is no scan -- '
  'the screen reads that as "kept, not read yet" and offers to read it. '
  'A kept file that has since been read appears once, as its scan. '
  '0694, 0695, 0698, 0714.';
