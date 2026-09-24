-- =====================================================================
-- iAkauntan :: 0705 what the paper said the tax was
--
-- Asked for after the line-by-line prompt landed: "in some cases the tax
-- is calculated in total instead of in single item do also ponder on
-- that".
--
-- A supplier's document often states ONE tax figure for the whole bill.
-- This system computes tax per LINE, all the way down: `app.calc_
-- document_line` charges each line at its own code, and the header's
-- `tax_amount` is DERIVED -- `0009`'s trigger sets it to
-- `sum(lines.tax_amount)` every time a line moves. So a document-level
-- figure read off a PDF has nowhere to be stored, and anything written
-- there is overwritten by the next keystroke.
--
-- That per-line model is correct and stays. MyInvois requires tax per
-- line item, the SST return reads the line, and so does the posting.
--
-- What was missing is the CHECK. The reading already captures the
-- paper's subtotal, tax and total -- they are in `ocr_scans.extracted`
-- and have been since `0111` -- and nothing ever compared them with
-- what the lines come to. So a bill whose codes are wrong, or whose
-- lines round to a different sen, ties to nothing and says so nowhere.
--
-- This is the read that makes the comparison possible. The comparing
-- and the warning are the app's; all the database owes it is "what did
-- the paper say", for the document in front of somebody.
--
-- ---------------------------------------------------------------------
-- Why it goes through the attachment
--
-- No new columns. The paper's figures already exist in exactly one
-- place, and copying them onto the document would be a second copy to
-- drift -- worse, a copy that a re-scan would leave stale. A document
-- has attachments; an attachment has scans; the newest successful scan
-- on any of them is what the paper said.
-- =====================================================================

create or replace function public.document_scan_totals(
  p_org_id   uuid,
  p_table    text,
  p_record_id uuid)
returns table (
  scan_id    uuid,
  read_at    timestamptz,
  file_name  text,
  subtotal   numeric,
  tax_amount numeric,
  total      numeric)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select s.id,
         coalesce(s.finished_at, s.created_at),
         a.file_name,
         -- `jsonb` to numeric through text, because a figure the reader
         -- returned as a JSON number and one it returned as a string
         -- are the same figure to everybody except a cast.
         nullif(s.extracted ->> 'subtotal', '')::numeric,
         nullif(s.extracted ->> 'tax_amount', '')::numeric,
         nullif(s.extracted ->> 'total_amount', '')::numeric
    from public.ocr_scans s
    join public.attachments a
      on a.id = s.attachment_id and a.org_id = s.org_id
   where app.is_org_member(p_org_id)
     and s.org_id = p_org_id
     and a.entity_table = p_table
     and a.entity_id = p_record_id
     and s.status = 'ok'
     and s.extracted is not null
   -- The newest reading wins. A document read twice -- which `0698`
   -- made ordinary -- is described by what the second reader said, not
   -- by whatever the first one got wrong.
   order by coalesce(s.finished_at, s.created_at) desc
   limit 1;
$$;

comment on function public.document_scan_totals(uuid, text, uuid) is
  'What the SCANNED paper said this document''s subtotal, tax and total '
  'were, from the newest successful reading of any file attached to it. '
  'For comparing against what the lines actually come to: this system '
  'computes tax per line and a supplier often states one figure for the '
  'whole bill, and until 0705 nothing checked the two against each '
  'other. Answers no rows where nothing was read. 0705.';

revoke all on function public.document_scan_totals(uuid, text, uuid)
  from public, anon;
grant execute on function public.document_scan_totals(uuid, text, uuid)
  to authenticated;
