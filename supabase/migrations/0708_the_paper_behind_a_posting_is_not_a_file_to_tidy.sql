-- =====================================================================
-- iAkauntan :: 0708 the paper behind a posting is not a file to tidy
--
--   all uploded documents should be saved in record no matter it was
--   used or not / if used and attached it csnt be deleted but if not
--   used and attached it's to have option to delete
--
-- `deleteAttachment` removed the object and the row, unconditionally,
-- from a button beside every file. The supplier's invoice that a bill
-- was read off and then posted from went the same way as a photograph
-- somebody took twice.
--
-- That file is not clutter. It is the evidence behind a ledger entry:
-- section 82 of the Income Tax Act 1967 requires the records supporting
-- a return to be kept for seven years, and `0705`'s banner compares a
-- document against the figures printed on exactly this file. Deleting
-- it leaves a posted journal with nothing to explain it -- which is the
-- same argument `0238` made for making the ledger append-only, about
-- the same evidence.
--
-- ---------------------------------------------------------------------
-- What "used" means, and why the app cannot be the one to decide
--
-- A file is EVIDENCE when either is true:
--
--   * the record it is filed against is POSTED. Its journal is in the
--     ledger and this is what the ledger was built from.
--   * a successful reading of it FILLED SOMETHING IN -- `ocr_scans`
--     recorded what it became (`posted_id`, `0694`), or the record it
--     is filed against carries `entry_source = 'ai_smartscan'`, which
--     `0707` writes precisely when a reading filled it. Those figures
--     were never keyed by anybody, so the page they came off is the
--     only way to check them.
--
-- Anything else keeps its delete button: a photograph taken twice, a
-- page captured against a draft nobody acted on, the wrong file
-- attached to the right bill.
--
-- The refusal is a TRIGGER rather than a hidden button, for CLAUDE.md's
-- first rule. A button the app declines to draw is not a rule; the row
-- is reachable from PostgREST by anybody who may write the table, and
-- `deleteAttachmentById` exists for a file whose row was never shown.
--
-- ---------------------------------------------------------------------
-- And the cascade still has to work
--
-- `app.delete_attachments_of_row` clears a record's files when the
-- record goes, and a company being deleted cascades through everything.
-- Neither is somebody tidying up a file.
--
-- Both fall out of one rule: a file is evidence OF something, so if the
-- record it belongs to is already gone it is evidence of nothing. That
-- check is the first thing `attachment_is_evidence` does. The
-- organization check in the trigger is the same idea one level up.
--
-- Nothing is lost by it: a POSTED document cannot be deleted at all --
-- `0402` -- so the paper behind a posting never reaches that path.
-- What it buys is a draft somebody scanned and then thought better of,
-- which `supabase/tests/scan_inbox.sql` caught being made undeletable
-- with a message about seven years of record keeping, on a document
-- that was never a record of anything.
-- =====================================================================

create or replace function app.attachment_is_evidence(p_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_table  text;
  v_entity uuid;
  v_org    uuid;
  v_posted boolean := false;
  v_exists boolean;
  v_source text;
begin
  select a.entity_table, a.entity_id, a.org_id
    into v_table, v_entity, v_org
    from public.attachments a where a.id = p_id;
  if v_table is null then
    return false;
  end if;

  -- THE RECORD IT BELONGS TO HAS TO STILL BE THERE.
  --
  -- This is the first check rather than an afterthought, and
  -- `scan_inbox.sql` is what insisted on it: deleting a DRAFT bill
  -- cascades through `app.delete_attachments_of_row` to its files, and
  -- a rule that refused there would make a draft somebody scanned and
  -- thought better of impossible to delete -- with a message about
  -- seven years of record keeping, on a document that was never a
  -- record of anything.
  --
  -- Nothing is lost by it. A posted document cannot be deleted at all
  -- (`0402`), so the paper behind a posting cannot reach this line; and
  -- a file whose record is already gone is evidence of nothing.
  if to_regclass('public.' || quote_ident(v_table)) is null then
    return false;
  end if;
  execute format(
    'select exists (select 1 from public.%I d '
    '                where d.id = $1 and d.org_id = $2)', v_table)
    into v_exists using v_entity, v_org;
  if not coalesce(v_exists, false) then
    return false;
  end if;

  -- A reading of this file that became, or filled, a record.
  if exists (select 1 from public.ocr_scans s
              where s.attachment_id = p_id
                and s.status = 'ok'
                and s.posted_id is not null) then
    return true;
  end if;

  -- The three tables a posting can hang off. `contacts` is not among
  -- them: a contact posts nothing, so a letterhead filed against one is
  -- a picture of a letterhead.
  if v_table in ('sales_documents', 'purchase_documents', 'expenses') then
    execute format(
      'select d.gl_entry_id is not null, d.entry_source '
      '  from public.%I d where d.id = $1 and d.org_id = $2',
      v_table)
      into v_posted, v_source
      using v_entity, v_org;

    if coalesce(v_posted, false) then
      return true;
    end if;

    -- `0707` writes this exactly when a reading filled the record in.
    -- Paired with "a successful reading of THIS file exists", so one
    -- scanned bill does not lock every other page somebody files
    -- against it afterwards.
    if v_source = 'ai_smartscan'
       and exists (select 1 from public.ocr_scans s
                    where s.attachment_id = p_id and s.status = 'ok') then
      return true;
    end if;
  end if;

  return false;
end;
$$;

comment on function app.attachment_is_evidence(uuid) is
  'Whether this file is what a posting or a reading was built from, and '
  'therefore cannot be deleted. True when the record it is filed '
  'against is posted, or when a successful reading of it produced or '
  'filled that record. 0708.';

revoke all on function app.attachment_is_evidence(uuid) from public, anon;
grant execute on function app.attachment_is_evidence(uuid)
  to authenticated, service_role;

create or replace function app.refuse_deleting_evidence()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- The company is already gone and these rows are cascading away
  -- behind it. `app.write_audit_log` and
  -- `app.refuse_posted_document_change` both make this check, for this
  -- reason and only on a delete.
  if not exists (select 1 from public.organizations o
                  where o.id = old.org_id) then
    return old;
  end if;

  if app.attachment_is_evidence(old.id) then
    raise exception
      '% is what this record was built from -- it is posted, or its '
      'figures were read off this page and never keyed by anybody -- so '
      'it stays with the record. Section 82 of the Income Tax Act 1967 '
      'asks for the paperwork behind a return to be kept for seven '
      'years. A file nothing was built from can still be removed.',
      old.file_name
      using errcode = '42501';
  end if;

  return old;
end;
$$;

drop trigger if exists refuse_deleting_evidence on public.attachments;
create trigger refuse_deleting_evidence
  before delete on public.attachments
  for each row execute function app.refuse_deleting_evidence();

-- ---------------------------------------------------------------------
-- What the screen needs to know before it draws the button
--
-- The trigger is the rule. This is so the card can say "this one stays"
-- rather than offering a button that fails -- one round trip for the
-- whole list, rather than one per file.
-- ---------------------------------------------------------------------
create or replace function public.attachments_of(
  p_org_id uuid, p_table text, p_record_id uuid)
returns table (
  id           uuid,
  file_name    text,
  storage_path text,
  mime_type    text,
  file_size    bigint,
  created_at   timestamptz,
  is_evidence  boolean)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select a.id, a.file_name, a.storage_path, a.mime_type,
         a.file_size::bigint, a.created_at,
         app.attachment_is_evidence(a.id)
    from public.attachments a
   where app.is_org_member(p_org_id)
     and a.org_id = p_org_id
     and a.entity_table = p_table
     and a.entity_id = p_record_id
   order by a.created_at desc;
$$;

comment on function public.attachments_of(uuid, text, uuid) is
  'The files filed against a record, each saying whether it is evidence '
  'a posting or a reading was built from. The screen draws no delete '
  'button on those; app.refuse_deleting_evidence is what actually '
  'refuses. 0708.';

revoke all on function public.attachments_of(uuid, text, uuid)
  from public, anon;
grant execute on function public.attachments_of(uuid, text, uuid)
  to authenticated;
