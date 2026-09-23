-- =====================================================================
-- iAkauntan :: 0694 where the paper ended up
--
-- `ocr_scans` has recorded, since the reader was built, what was read,
-- what it cost, which provider answered and what kind of paper somebody
-- decided it was. It has never recorded THE ONE THING a person wants to
-- know a week later: what did this photograph become?
--
-- That question had no answer anywhere. The scan row knows its
-- attachment; the attachment knows which table and record it is filed
-- against; and the link between the two was only ever walked in one
-- direction, by a screen showing the attachments on a document. Nothing
-- could start from the pile of paper and ask where each sheet went --
-- which is the whole of "I scanned that receipt, where is it?", and the
-- reason a scan that quietly produced nothing was indistinguishable
-- from one that posted a bill.
--
-- ---------------------------------------------------------------------
-- Read off the attachment, not handed in by the caller
--
-- The obvious shape is `record_scan_posting(table, id)`, and it is
-- wrong in a way that would not show up for months. The attachment's
-- own `entity_table` and `entity_id` are where the FILE actually went:
-- `refileAttachment` moves the storage object and the row together, and
-- a trigger refuses a row whose path disagrees with its columns. A
-- second, independently supplied pair could differ from that, and then
-- the inbox would confidently name a document the picture is not filed
-- against.
--
-- So the default is to take both off the attachment, and there is
-- nothing to get wrong. The explicit pair is kept for the one case that
-- needs it -- a bank statement, which is filed against
-- `bank_transactions` with a placeholder id because it becomes forty
-- rows and not one -- and it is checked against `scan_targets` so it
-- cannot be an arbitrary string.
--
-- ---------------------------------------------------------------------
-- Why a label is resolved here and not in Dart
--
-- `scan_inbox` returns "PB-1041" and a date, not a table name and a
-- uuid. The alternative is the client fetching from five tables to put
-- one line on screen, which is five round trips per page and five more
-- places for a permission to be wrong. The lookup is a left join per
-- destination: a document that was deleted afterwards comes back with a
-- null label rather than vanishing from the list, because "this scan
-- became a bill that no longer exists" is the answer, and a row that
-- silently disappeared would read as a scan that never happened.
-- =====================================================================

alter table public.ocr_scans
  add column if not exists posted_table text;

alter table public.ocr_scans
  add column if not exists posted_id uuid;

alter table public.ocr_scans
  add column if not exists posted_at timestamptz;

-- All three or none of them. A `posted_table` with no id names nothing
-- and an id with no table cannot be looked up in anything; either one
-- alone would put a row in the inbox that claims to have become
-- something and cannot say what.
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'ocr_scans_posted_together') then
    alter table public.ocr_scans
      add constraint ocr_scans_posted_together check (
        (posted_table is null and posted_id is null and posted_at is null)
        or
        (posted_table is not null and posted_id is not null
         and posted_at is not null));
  end if;
end $$;

comment on column public.ocr_scans.posted_table is
  'Which table the record this scan became lives in, or null while it '
  'has become nothing. Copied off the attachment by '
  '`record_scan_posting`, so it cannot disagree with where the file '
  'itself is filed. 0694.';

comment on column public.ocr_scans.posted_id is
  'The record this scan became. For a bank statement this is the '
  'placeholder the picture is parked against, because a statement '
  'becomes many rows and not one. 0694.';

-- The inbox reads newest first within an org, and filters on whether
-- anything came of the scan.
create index if not exists ocr_scans_inbox_idx
  on public.ocr_scans (org_id, created_at desc);

-- ---------------------------------------------------------------------
-- Recording it
-- ---------------------------------------------------------------------
create or replace function public.record_scan_posting(
  p_org_id uuid,
  p_attachment_id uuid,
  p_table text default null,
  p_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_scan  uuid;
  v_table text;
  v_id    uuid;
begin
  if not app.can_write(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  if p_table is null then
    -- The ordinary path. Where the FILE went is where the scan went,
    -- and the attachment is the only row that knows both.
    select a.entity_table, a.entity_id into v_table, v_id
      from public.attachments a
     where a.id = p_attachment_id and a.org_id = p_org_id;
    if v_table is null then
      raise exception 'No such attachment in this company: %',
        p_attachment_id using errcode = 'P0002';
    end if;
  else
    -- The statement case, and anything else that becomes many rows.
    -- Checked against the destinations this platform has configured so
    -- the column cannot fill up with typed strings.
    if not exists (select 1 from public.scan_targets
                    where table_name = p_table) then
      raise exception 'Nothing scans into %', p_table
        using errcode = 'P0002';
    end if;
    if p_id is null then
      raise exception 'A posting needs the record it posted to'
        using errcode = '23514';
    end if;
    v_table := p_table;
    v_id    := p_id;
  end if;

  select id into v_scan
    from public.ocr_scans
   where org_id = p_org_id
     and attachment_id = p_attachment_id
   order by created_at desc
   limit 1;

  -- Not an error, for `set_scan_document_kind`'s reason: a capture
  -- nobody read still reaches the end of the flow, and there is simply
  -- no scan row to write on.
  if v_scan is null then
    return null;
  end if;

  update public.ocr_scans
     set posted_table = v_table,
         posted_id    = v_id,
         posted_at    = now()
   where id = v_scan;
  return v_scan;
end;
$$;

revoke all on function public.record_scan_posting(uuid, uuid, text, uuid)
  from public;
grant execute on function public.record_scan_posting(uuid, uuid, text, uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- The pile of paper, and what each sheet became
-- ---------------------------------------------------------------------
create or replace function public.scan_inbox(
  p_org_id uuid,
  p_limit integer default 100,
  p_only text default 'all')
returns table (
  scan_id       uuid,
  attachment_id uuid,
  file_name     text,
  storage_path  text,
  scanned_at    timestamptz,
  provider      text,
  status        text,
  error         text,
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
         s.storage_path,
         s.created_at,
         s.provider,
         s.status,
         s.error,
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
   order by s.created_at desc
   limit greatest(1, least(coalesce(p_limit, 100), 500));
$$;

revoke all on function public.scan_inbox(uuid, integer, text) from public;
grant execute on function public.scan_inbox(uuid, integer, text)
  to authenticated;

comment on function public.scan_inbox(uuid, integer, text) is
  'Every reading this company has taken, newest first, with the record '
  'it became resolved to something a person recognises. `p_only` is '
  'all, posted or unposted. 0694.';

comment on function public.record_scan_posting(uuid, uuid, text, uuid) is
  'Records what a reading became. Refuses a caller who may not write '
  'in this company; refuses an attachment that is not this company''s; '
  'refuses a table no `scan_targets` row names, and an explicit table '
  'with no record id. Answers null -- not an error -- where the '
  'capture was never read and there is no scan row to write on. With '
  'no table given it copies both off the attachment, so the scan '
  'cannot claim to have become something the file is not filed '
  'against. 0694.';
