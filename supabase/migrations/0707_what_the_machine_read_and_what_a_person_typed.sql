-- =====================================================================
-- iAkauntan :: 0707 what the machine read, and what a person typed
--
--   all entry which are created with AI SmartScan will be tagged as
--   "AI Scan" in the background database and in any where that shows
--   posted draft overdue complete it should show "Ai Scan" beside it
--   also
--
-- Nothing on a record has ever said where its contents came from. A
-- bill somebody typed off a PDF in front of them and a bill a model
-- read off the same PDF are the same row, and the second one is the one
-- worth a second look -- a reader that mistakes 1,086.12 for 1,086.72
-- produces a document that balances, posts and reconciles to nothing.
--
-- ---------------------------------------------------------------------
-- Where the answer already half was
--
-- `0694` put `posted_table`, `posted_id` and `posted_at` on `ocr_scans`,
-- so the SCAN knows what it became. That is the right place for the
-- audit trail and it stays. What it cannot do is be read: every list in
-- this product selects the document table and nothing else, and a join
-- per list -- bills, invoices, orders, receipts, expenses, aging, the
-- taxman's queue -- is a join to forget in the next list somebody adds.
--
-- So the record carries it as well, written in the SAME STATEMENT as
-- the link on `ocr_scans` -- `record_scan_posting`, below -- which is
-- what stops the two from drifting.
--
-- ---------------------------------------------------------------------
-- Which tables
--
-- The four of `scan_targets` that are a single record somebody opens:
-- `sales_documents`, `purchase_documents`, `expenses`, `contacts`.
--
-- `bank_transactions` is deliberately not among them. A statement is
-- ONE reading that becomes a hundred rows -- `scan_targets.repeats` is
-- true for exactly that reason, and `record_scan_posting` files it
-- against a placeholder id -- so there is no single record to tag, and
-- tagging all hundred would say "this line was scanned" about a line
-- whose whole table arrives that way.
--
-- ---------------------------------------------------------------------
-- Null, and what it means
--
-- Null is a person typed it, which is every row in every existing
-- database and the overwhelming majority of every row after this. The
-- column is text rather than a boolean because the question is WHERE
-- FROM, and this is not the only answer it will ever have: a bank
-- import and an AutoCount migration are the same question, and the
-- second already has `import_source` for its own reasons.
-- =====================================================================

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'sales_documents', 'purchase_documents', 'expenses', 'contacts']
  loop
    execute format(
      'alter table public.%I add column if not exists entry_source text',
      v_table);
    execute format(
      'alter table public.%I drop constraint if exists %I',
      v_table, v_table || '_entry_source_ck');
    execute format(
      'alter table public.%I add constraint %I check '
      '(entry_source is null or entry_source in (%L))',
      v_table, v_table || '_entry_source_ck', 'ai_smartscan');
    execute format(
      'comment on column public.%I.entry_source is %L',
      v_table,
      'Where this record''s contents came from. Null is a person typed '
      'it, which is nearly everything. ''ai_smartscan'' is a model read '
      'it off a document -- shown as "AI Scan" beside the status in '
      'every list, because a figure nobody keyed is the one worth '
      'looking at twice. Written beside ocr_scans.posted_id, in the '
      'same statement, so the two cannot disagree. 0707.');
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Stamped where the link is already written
--
-- Restated from what is in the database, with the `update` at the end
-- extended. Doing it here rather than in the app is the whole point:
-- there are four flows that turn a reading into a record and this is
-- the one thing all of them already call.
--
-- `v_table` is checked against `scan_targets` on the statement path and
-- comes off the attachment on the ordinary one, so it is not a string
-- somebody typed -- but `format(%I)` anyway, because "not a string
-- somebody typed" is a property of today's callers.
-- ---------------------------------------------------------------------
create or replace function public.record_scan_posting(
  p_org_id uuid, p_attachment_id uuid, p_table text default null::text,
  p_id uuid default null::uuid)
returns uuid
language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
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

  -- 0707. The record says so too, because no list joins to `ocr_scans`.
  -- Only the four tables that are a single record somebody opens; a
  -- bank statement's hundred lines are not each "a scanned entry".
  if v_table in ('sales_documents', 'purchase_documents', 'expenses',
                 'contacts') then
    execute format(
      'update public.%I set entry_source = %L '
      ' where id = $1 and org_id = $2 and entry_source is null',
      v_table, 'ai_smartscan')
      using v_id, p_org_id;
  end if;

  return v_scan;
end;
$function$;

-- ---------------------------------------------------------------------
-- What is already there
--
-- Two passes, because two different things count as "created with
-- SmartScan" and only the first was ever recorded:
--
--   1. a reading that BECAME a record -- `ocr_scans.posted_id`, which
--      `record_scan_posting` has been writing since `0694`;
--
--   2. a record whose own PAPERWORK was read. This is the case the
--      report came from: a bill is created, the supplier's PDF is
--      attached to it, and reading it fills the lines. Nothing calls
--      `record_scan_posting` on that path -- the file was already
--      filed -- so `posted_id` is null and the only evidence is that a
--      successful scan exists against an attachment on the row.
--
-- The second pass is the wider one and it is deliberately limited to
-- SUCCESSFUL readings: a scan that failed filled nothing in, and the
-- document beside it was typed.
-- ---------------------------------------------------------------------
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'sales_documents', 'purchase_documents', 'expenses', 'contacts']
  loop
    execute format(
      'update public.%I t set entry_source = ''ai_smartscan'' '
      ' where t.entry_source is null '
      '   and exists (select 1 from public.ocr_scans s '
      '                where s.posted_table = %L and s.posted_id = t.id '
      '                  and s.org_id = t.org_id)',
      v_table, v_table);

    execute format(
      'update public.%I t set entry_source = ''ai_smartscan'' '
      ' where t.entry_source is null '
      '   and exists (select 1 from public.attachments a '
      '               join public.ocr_scans s '
      '                 on s.attachment_id = a.id and s.org_id = a.org_id '
      '                where a.entity_table = %L and a.entity_id = t.id '
      '                  and a.org_id = t.org_id '
      '                  and s.status = ''ok'')',
      v_table, v_table);
  end loop;
end $$;
