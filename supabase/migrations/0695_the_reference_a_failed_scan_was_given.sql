-- =====================================================================
-- iAkauntan :: 0695 the reference a failed scan was given
--
-- `0680` mints a reference when a scan fails, writes it onto the row,
-- and tells the person to quote it. `0694` then built the screen where
-- a person looks at a failed scan -- and did not show it.
--
-- So the one identifier the whole arrangement exists to hand over was
-- on the row, in the logs, and nowhere a person could read it. Quoting
-- it was impossible unless somebody with SQL went and looked, which is
-- exactly the trip `0680` was written to save.
--
-- ---------------------------------------------------------------------
-- Dropped and recreated, not replaced
--
-- `create or replace function` cannot add a column to a returning
-- function's signature -- Postgres refuses to change the return type --
-- so this drops it first. Safe here and worth saying why: `scan_inbox`
-- is read by one screen, nothing holds a reference to it across a
-- migration, and the drop and the create are in one transaction, so
-- there is no window where the function does not exist.
-- =====================================================================

drop function if exists public.scan_inbox(uuid, integer, text);

-- `or replace` after a drop is a no-op, and it is here on purpose:
-- `scripts/mutate_sql.py` finds a function by that phrase, and a
-- migration it cannot find is a function nothing can sweep.
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
  -- `0680`'s reference, and `0695`'s whole reason. What the person is
  -- told to quote, so it has to be somewhere they can read it.
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
         s.storage_path,
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
   order by s.created_at desc
   limit greatest(1, least(coalesce(p_limit, 100), 500));
$$;

revoke all on function public.scan_inbox(uuid, integer, text) from public;
grant execute on function public.scan_inbox(uuid, integer, text)
  to authenticated;

comment on function public.scan_inbox(uuid, integer, text) is
  'Every reading this company has taken, newest first, with the record '
  'it became resolved to something a person recognises and the '
  'reference a failed one was given. `p_only` is all, posted or '
  'unposted. 0694, 0695.';
