-- =====================================================================
-- iAkauntan :: 0715 one sheet of paper, one row
--
-- Reported with a screenshot: one uploaded AmBank statement, and the
-- inbox showing it TWICE -- two rows, the same file name, the same
-- date, the same sentence under each. Read as "it created a duplicate
-- of the file", which is exactly what it looks like.
--
-- ---------------------------------------------------------------------
-- Nothing was duplicated
--
-- The database says so plainly. ONE attachment, uploaded at 17:45:58,
-- and TWO rows in `ocr_scans` against it -- 17:46:32 and 17:47:25.
-- One file, read twice, fifty-three seconds apart.
--
-- That is `0698` working as designed: "Read it again" makes a NEW scan
-- row rather than overwriting the old one, because a second reading has
-- its own provider, its own cost and its own answer, and throwing the
-- first away would destroy the evidence for "why was I charged twice".
--
-- The defect is that `scan_inbox` returns one row per SCAN, and the
-- screen it feeds opens with "the pile of paper, and what each sheet
-- became". A pile has one of each sheet. Two rows for one document,
-- identical down to the sentence under them, is not an audit trail on
-- screen -- it is a list that appears to have duplicated somebody's
-- file, with no way to tell from the outside that it did not.
--
-- `0714` was one migration too early about this. Its own comment worried
-- about "showing both would list one sheet of paper twice with two
-- different stories about it" -- and handled only the kept-file case,
-- while the scan-against-scan case was already there and older.
--
-- ---------------------------------------------------------------------
-- One row per attachment, and WHICH row
--
-- Not simply the latest. A sheet read once into a posted bill and then
-- re-read out of curiosity would show the second reading, and the
-- posting -- the whole answer the screen exists to give -- would
-- vanish from the list.
--
-- So: the reading that POSTED something, if any did, and otherwise the
-- most recent. What became of the paper outranks what was most recently
-- asked of it.
--
-- A scan whose attachment is GONE cannot be grouped -- `0702` sets
-- `attachment_id` to null when a document is deleted, and every such
-- scan would collapse into one row about nothing. Those are grouped by
-- their own id, which is to say not grouped, and each still appears.
--
-- ---------------------------------------------------------------------
-- And the earlier readings are said, not hidden
--
-- `readings` counts them. A row that silently dropped a reading would
-- be the same dishonesty in the other direction: somebody charged for
-- two readings must be able to see that two happened. The screen says
-- "read 2 times" and the count is on the row rather than behind a tap,
-- because the question it answers -- "why was I charged twice" -- is
-- asked by somebody looking at a list.
-- =====================================================================

-- A column added to a `returns table` changes the row type, and
-- Postgres will not replace a function whose OUT parameters differ. So
-- it is dropped and rebuilt, with the grant re-issued below -- dropping
-- takes the grant with it, and a function nobody may execute is a
-- screen that shows an empty list and no reason.
drop function if exists public.scan_inbox(uuid, integer, text);

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
  corrected     boolean,
  -- How many times this sheet of paper has been read. `0715`. One
  -- normally; more once somebody has used "Read it again", and the
  -- reason the row is not silently hiding the others.
  readings      integer)
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
         s.corrected is not null,
         greatest(s.readings, 1)
    from (
           -- One per sheet of paper. `distinct on` needs the group in
           -- front of its own ORDER BY, so the choice is made here and
           -- the list's own ordering happens at the bottom.
           --
           -- A scan with no attachment left cannot be grouped with
           -- anything -- `0702` nulls it when the document goes -- so
           -- it is grouped by its own id, which is to say not at all.
           select distinct on (coalesce(s2.attachment_id::text, s2.id::text))
                  s2.*,
                  (select count(*)::integer from public.ocr_scans s3
                    where s3.attachment_id is not null
                      and s3.attachment_id = s2.attachment_id) as readings
             from public.ocr_scans s2
            where s2.org_id = p_org_id
            order by coalesce(s2.attachment_id::text, s2.id::text),
                     -- What it BECAME outranks what was last asked of
                     -- it: a sheet read into a bill and then re-read
                     -- would otherwise lose the bill off the list.
                     (s2.posted_table is not null) desc,
                     s2.created_at desc
         ) s
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
         false,
         0
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
  'The pile of paper: one row per sheet. A document read more than once '
  'appears once -- the reading that posted something, or the most '
  'recent -- with `readings` saying how many there were, because a '
  'second reading is a second charge and must not vanish. A file kept '
  'and never read has a null `scan_id` and `readings` of 0. '
  '0694, 0695, 0698, 0714, 0715.';
