-- =====================================================================
-- iAkauntan :: 0709 a kind of paper the list has never heard of
--
--   When something is sent it don't get any data or recognise any data
--   it should prompt back a popup where use can view and review the
--   document or image and inform what kind of document it is / if it's
--   not in list there should be a other option where freestyle text to
--   key in document type name
--
-- The sheet that asks "What is this?" offers eight destinations and
-- nothing else. Somebody holding a document the list has never heard of
-- -- a payment voucher, a petty cash slip, a cash bill from a
-- hardware shop, a delivery order in Chinese -- has no way to say so.
-- They close the sheet, and what the platform learns is nothing.
--
-- That is the wrong way round. A reading that came back empty is the
-- most valuable thing in this whole module: it is a document the
-- product cannot yet handle, in the hands of somebody who knows exactly
-- what it is and is willing to say.
--
-- ---------------------------------------------------------------------
-- Why a column rather than a row in `scan_document_kinds`
--
-- Because it is not a kind yet. `scan_document_kinds` is the platform's
-- vocabulary -- `0681` hands the reader a destination's columns off the
-- back of it, and `set_scan_document_kind` refuses a code that is not
-- in it, deliberately, so the column cannot fill up with typed
-- strings.
--
-- That guard stays. What somebody types is not a code, it is EVIDENCE
-- FOR ONE: a hundred scans named "payment voucher" is the argument for
-- adding payment vouchers, and until somebody makes that decision the
-- typed name should not be pretending to be a kind the reader can be
-- asked about.
--
-- So it lands beside the code, not in it, and `platform_named_kinds`
-- below is what turns a pile of them into that argument.
-- =====================================================================

alter table public.ocr_scans
  add column if not exists document_kind_named text;

comment on column public.ocr_scans.document_kind_named is
  'What somebody typed when nothing on the list fitted. Not a code and '
  'not a kind -- `scan_document_kinds` is the vocabulary and '
  '`set_scan_document_kind` still refuses anything not in it. This is '
  'the evidence for adding one. 0709.';

-- ---------------------------------------------------------------------
-- The same function, with somewhere to put the typed name
--
-- Dropped and recreated rather than replaced: a new parameter with a
-- default would be an OVERLOAD, and two functions of the same name is
-- what `check_ambiguous_overloads.py` exists to refuse -- PostgREST
-- picks between them by the keys in the body, so the one somebody gets
-- depends on what they happened to send.
--
-- Restated in full from what is in the database, with the trim, the
-- guard and the two "not an error" cases exactly as they were.
-- ---------------------------------------------------------------------
drop function if exists public.set_scan_document_kind(uuid, uuid, text);

create or replace function public.set_scan_document_kind(
  p_org_id uuid,
  p_attachment_id uuid,
  p_document_kind text,
  p_named text default null)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_scan  uuid;
  v_kind  text;
  v_named text;
begin
  if not app.can_write(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  v_kind := nullif(btrim(coalesce(p_document_kind, '')), '');
  if v_kind is not null
     and not exists (select 1 from public.scan_document_kinds
                      where code = v_kind) then
    raise exception 'No such kind of document: %', v_kind
      using errcode = 'P0002';
  end if;

  -- 0709. Capped, because it goes on a console list and a paragraph
  -- pasted into it would be a row nobody can read past. Left as typed
  -- otherwise -- "Baucar Bayaran" and "payment voucher" are the same
  -- document and folding them together is a decision for whoever reads
  -- the list, not for the box it was typed into.
  v_named := nullif(btrim(coalesce(p_named, '')), '');
  if v_named is not null then
    v_named := left(v_named, 120);
  end if;

  -- A switched-off kind is NOT refused. The list moves under people,
  -- and a reading somebody is looking at right now was offered the
  -- kinds that were on the list when it loaded. Refusing it here would
  -- lose the answer to a race nobody can see.
  select id into v_scan
    from public.ocr_scans
   where org_id = p_org_id
     and attachment_id = p_attachment_id
   order by created_at desc
   limit 1;

  if v_scan is null then
    -- Not an error. The on-device reader records its scan and the
    -- server one records its own, and a capture that was never read at
    -- all still reaches this call with a kind somebody typed. There is
    -- simply nothing to write it on.
    return null;
  end if;

  update public.ocr_scans
     set document_kind = v_kind,
         -- Only ever set, never cleared by a call that says nothing
         -- about it: the kind is chosen again every time the sheet
         -- opens, and the typed name is the answer to a question asked
         -- once.
         document_kind_named = coalesce(v_named, document_kind_named)
   where id = v_scan;
  return v_scan;
end;
$function$;

-- The comment went with the drop, and `check_undocumented_writes.py`
-- caught that: a write a signed-in caller can reach with no
-- `comment on function` has told them nothing about what it refuses,
-- and for a write the refusals are the rule. Restated from `0614` with
-- the new parameter's own sentence.
comment on function
  public.set_scan_document_kind(uuid, uuid, text, text) is
  'Files the most recent scan of an attachment as a kind of document. '
  'Accepts a kind that has since been switched off, and answers null '
  'where there is no scan to write on. Refuses a kind that is not in '
  'scan_document_kinds. p_named is what somebody TYPED when nothing on '
  'the list fitted -- it is not a kind, it is never cleared by a later '
  'call that says nothing about it, and it is capped at 120 '
  'characters. 0614, 0709.';

revoke all on function
  public.set_scan_document_kind(uuid, uuid, text, text) from public, anon;
grant execute on function
  public.set_scan_document_kind(uuid, uuid, text, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- What people are scanning that this product cannot place
--
-- The reason for collecting it. Platform-wide and across companies,
-- because the question is "what should the product handle next" and
-- that is not a question about one company's paperwork.
--
-- Names are folded case-insensitively and on whitespace only --
-- "Payment Voucher" and "payment voucher" are one row. Anything
-- cleverer is a decision for whoever reads this.
-- ---------------------------------------------------------------------
create or replace function public.platform_named_kinds(p_days integer
  default 90)
returns table (
  named      text,
  times      bigint,
  companies  bigint,
  last_seen  timestamptz)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select lower(regexp_replace(btrim(s.document_kind_named), '\s+', ' ', 'g')),
         count(*),
         count(distinct s.org_id),
         max(coalesce(s.finished_at, s.created_at))
    from public.ocr_scans s
   where app.is_platform_admin()
     and s.document_kind_named is not null
     and btrim(s.document_kind_named) <> ''
     and coalesce(s.finished_at, s.created_at)
         > now() - make_interval(days => greatest(p_days, 1))
   group by 1
   order by count(*) desc, 1;
$$;

comment on function public.platform_named_kinds(integer) is
  'What people typed when nothing on the scan kind list fitted, folded '
  'case-insensitively, commonest first. The argument for the next row '
  'in scan_document_kinds. Platform admin only. 0709.';

revoke all on function public.platform_named_kinds(integer)
  from public, anon;
grant execute on function public.platform_named_kinds(integer)
  to authenticated;
