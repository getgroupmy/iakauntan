-- =====================================================================
-- iAkauntan :: 0684 what the reader got wrong
--
-- `ocr_scans.extracted` holds what the model said. Nothing holds what
-- the person changed it to.
--
-- `showScanResult(canApply: true)` puts the reading on screen beside
-- the fields it is about to fill, and somebody corrects the total, or
-- the date, or the supplier's name. That correction is the ONLY ground
-- truth in this system. It is produced by hand, for free, by somebody
-- who is holding the paper and looking at it -- and it is handed to the
-- form and then dropped on the floor.
--
-- ---------------------------------------------------------------------
-- What it is worth
--
-- Every question anybody is about to ask about readers is unanswerable
-- without it:
--
--   * Is Gemini cheaper per scan, or cheaper per scan that has to be
--     redone by hand? RM 0.10 against RM 0.30 decides nothing until the
--     second number exists.
--   * Is Claude on Opus worth three times Gemini on Flash, or is the
--     difference invisible on a one-page receipt and real only on the
--     awkward layouts?
--   * WHICH FIELD does each reader get wrong? They do not fail evenly.
--     A reader that reads totals perfectly and dates badly is a
--     different problem from one that is generally vague, and the fix
--     for the first is a sentence in that field's description rather
--     than a different reader.
--
-- None of that is answerable by looking at a scan. It is answerable by
-- counting corrections, which costs one column and a timestamp.
--
-- ---------------------------------------------------------------------
-- Three states, not two
--
-- The obvious design is a `corrected` column, and it cannot tell the
-- two interesting cases apart. A scan with no correction is either a
-- reading somebody checked and agreed with -- the reader was RIGHT,
-- which is the datum this whole migration is for -- or a reading nobody
-- ever looked at. Those are opposite facts and they would both be null.
--
-- So `reviewed_at` is separate from `corrected`:
--
--   reviewed_at null                  nobody accepted this reading.
--                                     Abandoned, or read on the device
--                                     by a path that shows no dialog.
--   reviewed_at set, corrected null   accepted exactly as read. The
--                                     reader was right.
--   reviewed_at set, corrected set    somebody changed something, and
--                                     `corrected` is what to.
--
-- `corrected` is written ONLY where it differs. Storing the accepted
-- reading unconditionally would make every scan look corrected and
-- throw away the same distinction in a different disguise.
--
-- ---------------------------------------------------------------------
-- What counts as a difference
--
-- Not `jsonb <>`. `1900` and `1900.00` are the same money and different
-- JSON, and a reader marked wrong for writing a trailing zero would
-- bury the real signal under noise. So the comparison is per field and
-- by type: money as numeric, dates as date, text trimmed and
-- case-folded, and a null on one side against an empty string on the
-- other treated as agreement, because "the page does not print it" and
-- "I cleared the box" are the same statement about the paper.
--
-- `raw_text` is excluded and stripped on the way in. It is the reader's
-- own transcription, nobody edits it, and it is the largest thing on
-- the row.
--
-- The field list lives in `app.scan_corrected_fields` and nowhere else,
-- so the reporting below and the write path cannot disagree about what
-- a correction is.
-- =====================================================================

alter table public.ocr_scans
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid references auth.users (id),
  add column if not exists corrected   jsonb;

comment on column public.ocr_scans.reviewed_at is
  'When a person accepted this reading. Null means nobody ever did -- '
  'which is a different fact from accepting it unchanged, and the '
  'reason this is not folded into `corrected`. 0684.';

comment on column public.ocr_scans.reviewed_by is
  'Who accepted it. 0684.';

comment on column public.ocr_scans.corrected is
  'The accepted reading, written only where it DIFFERS from '
  '`extracted` -- so null beside a set `reviewed_at` means the reader '
  'was right, which is the datum this column exists to make '
  'countable. `raw_text` is stripped. 0684.';

-- Only the reviewed rows, which is the minority worth reporting on.
create index if not exists ocr_scans_reviewed_idx
  on public.ocr_scans (provider, reviewed_at)
  where reviewed_at is not null;

-- ---------------------------------------------------------------------
-- Which fields a person can correct
--
-- The dialog's own boxes. One list, read by both the write path and
-- the report, because two lists would drift and the drift would look
-- like a reader getting better.
-- ---------------------------------------------------------------------
create or replace function app.scan_corrected_fields()
returns table (field text, kind text)
language sql immutable
set search_path = pg_catalog, pg_temp as $$
  values
    ('supplier_name', 'text'),
    ('supplier_tax_id', 'text'),
    ('supplier_registration_no', 'text'),
    ('supplier_email', 'text'),
    ('supplier_phone', 'text'),
    ('supplier_address', 'text'),
    ('document_no', 'text'),
    ('document_date', 'date'),
    ('currency', 'text'),
    ('subtotal', 'money'),
    ('tax_amount', 'money'),
    ('total_amount', 'money'),
    ('lines', 'lines')
$$;

comment on function app.scan_corrected_fields() is
  'The fields a person can put right in the scan result dialog, and '
  'how each is compared. The single list both `app.scan_field_diff` '
  'and the accuracy report read. 0684.';

-- ---------------------------------------------------------------------
-- The comparison
-- ---------------------------------------------------------------------
create or replace function app.scan_same_text(a text, b text)
returns boolean
language sql immutable
set search_path = pg_catalog, pg_temp as $$
  -- Null and '' are the same statement about the paper: it does not
  -- print this. Case and surrounding space are not corrections.
  select lower(btrim(coalesce(a, ''))) = lower(btrim(coalesce(b, '')));
$$;

create or replace function app.scan_same_money(a text, b text)
returns boolean
language plpgsql immutable
set search_path = pg_catalog, pg_temp as $$
declare
  x numeric;
  y numeric;
begin
  -- A figure that will not parse is compared as the text it is, rather
  -- than silently becoming null and agreeing with everything.
  begin
    x := nullif(btrim(coalesce(a, '')), '')::numeric;
    y := nullif(btrim(coalesce(b, '')), '')::numeric;
  exception when others then
    return app.scan_same_text(a, b);
  end;
  if x is null and y is null then return true; end if;
  if x is null or y is null then return false; end if;
  return round(x, 2) = round(y, 2);
end;
$$;

create or replace function app.scan_same_date(a text, b text)
returns boolean
language plpgsql immutable
set search_path = pg_catalog, pg_temp as $$
declare
  x date;
  y date;
begin
  begin
    x := nullif(btrim(coalesce(a, '')), '')::date;
    y := nullif(btrim(coalesce(b, '')), '')::date;
  exception when others then
    return app.scan_same_text(a, b);
  end;
  return x is not distinct from y;
end;
$$;

-- Lines are compared as a whole: a bill whose third line moved is a
-- corrected bill, and which line it was is a question for the two
-- documents rather than for a counter.
create or replace function app.scan_same_lines(a jsonb, b jsonb)
returns boolean
language sql immutable
set search_path = pg_catalog, pg_temp as $$
  with norm as (
    select 'a' as side, ord, e.value as line
      from jsonb_array_elements(case when jsonb_typeof(a) = 'array'
                                     then a else '[]'::jsonb end)
           with ordinality e(value, ord)
    union all
    select 'b', ord, e.value
      from jsonb_array_elements(case when jsonb_typeof(b) = 'array'
                                     then b else '[]'::jsonb end)
           with ordinality e(value, ord)
  ), flat as (
    select side, ord,
           lower(btrim(coalesce(line ->> 'description', ''))) as d,
           coalesce(round((nullif(line ->> 'quantity', ''))::numeric, 4), 0) as q,
           coalesce(round((nullif(line ->> 'unit_price', ''))::numeric, 2), 0) as u,
           coalesce(round((nullif(line ->> 'amount', ''))::numeric, 2), 0) as m
      from norm
  )
  select not exists (
    select 1 from flat f
     full outer join flat g
       on g.side = 'b' and g.ord = f.ord
    where f.side = 'a'
      and (g.ord is null or f.d <> g.d or f.q <> g.q
           or f.u <> g.u or f.m <> g.m)
  ) and (
    select count(*) filter (where side = 'a')
         = count(*) filter (where side = 'b') from flat
  );
$$;

/**
 * The names of the fields that differ between a reading and what was
 * accepted. Empty means the reader was right.
 */
create or replace function app.scan_field_diff(
  p_extracted jsonb, p_accepted jsonb)
returns text[]
language sql stable
set search_path = pg_catalog, public, app, pg_temp as $$
  select coalesce(array_agg(f.field order by f.field), array[]::text[])
    from app.scan_corrected_fields() f
   where not case f.kind
     when 'text'  then app.scan_same_text(
                         p_extracted ->> f.field, p_accepted ->> f.field)
     when 'money' then app.scan_same_money(
                         p_extracted ->> f.field, p_accepted ->> f.field)
     when 'date'  then app.scan_same_date(
                         p_extracted ->> f.field, p_accepted ->> f.field)
     when 'lines' then app.scan_same_lines(
                         p_extracted -> f.field, p_accepted -> f.field)
     else true
   end;
$$;

comment on function app.scan_field_diff(jsonb, jsonb) is
  'Which of the correctable fields a person changed. Compared by type '
  'rather than by `jsonb <>`, so a trailing zero on a total is not a '
  'correction. 0684.';

-- ---------------------------------------------------------------------
-- Writing it
--
-- Shaped after `set_scan_document_kind` in `0614`, which has the same
-- job: a person's opinion about a reading, arriving with an attachment
-- id because that is what the caller is holding. Answers null where
-- there is no scan to write on rather than raising -- a capture that
-- was never read still reaches here.
-- ---------------------------------------------------------------------
create or replace function public.ocr_note_correction(
  p_org_id uuid,
  p_attachment_id uuid,
  p_accepted jsonb)
returns text[]
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  v_scan      uuid;
  v_extracted jsonb;
  v_accepted  jsonb;
  v_diff      text[];
begin
  if not app.can_write(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select id, extracted into v_scan, v_extracted
    from public.ocr_scans
   where org_id = p_org_id
     and attachment_id = p_attachment_id
   order by created_at desc
   limit 1;

  if v_scan is null then
    return null;
  end if;

  -- The reader's own transcription, off. Nobody edits it and it is the
  -- largest thing that would otherwise be stored twice.
  v_accepted := coalesce(p_accepted, '{}'::jsonb) - 'raw_text';
  v_diff := app.scan_field_diff(coalesce(v_extracted, '{}'::jsonb), v_accepted);

  update public.ocr_scans
     set reviewed_at = now(),
         reviewed_by = auth.uid(),
         -- Null where nothing moved. A reading accepted as it stands is
         -- the reader being right, and writing the accepted copy here
         -- anyway would make every scan look corrected.
         corrected = case when cardinality(v_diff) > 0 then v_accepted end
   where id = v_scan;

  return v_diff;
end;
$$;

comment on function public.ocr_note_correction(uuid, uuid, jsonb) is
  'Records that a person accepted the most recent scan of an '
  'attachment, and what they changed on the way. Returns the field '
  'names that differed -- empty where the reader was right, null where '
  'there was no scan to write on. 0684.';

revoke all on function public.ocr_note_correction(uuid, uuid, jsonb)
  from public, anon;
grant execute on function public.ocr_note_correction(uuid, uuid, jsonb)
  to authenticated;

-- ---------------------------------------------------------------------
-- And the question it was all for
--
-- Per reader: how many readings a person checked, how many they had to
-- change, and which field they changed. Platform-wide, because the
-- decision it informs -- which readers to offer, and what to charge for
-- them -- is the platform's.
--
-- The guard is in the WHERE clause rather than a raise: a non-admin
-- gets no rows, which is what `platform_scan_log` in `0680` settled on
-- for the same reason. A console that asks this while somebody's
-- session is being downgraded should draw an empty table, not throw.
-- ---------------------------------------------------------------------
create or replace function public.platform_scan_accuracy(
  p_days integer default 90)
returns table (
  provider    text,
  reviewed    bigint,
  corrected   bigint,
  accuracy    numeric,
  worst_field text,
  worst_count bigint)
language sql stable
security definer
set search_path = pg_catalog, public, app, pg_temp as $$
  with seen as (
    select s.provider, s.extracted, s.corrected
      from public.ocr_scans s
     where app.is_platform_admin()
       and s.reviewed_at is not null
       and s.reviewed_at > now() - make_interval(days => greatest(p_days, 1))
  ), fields as (
    select s.provider, unnest(
             app.scan_field_diff(coalesce(s.extracted, '{}'::jsonb),
                                 s.corrected)) as field
      from seen s
     where s.corrected is not null
  ), worst as (
    select distinct on (f.provider)
           f.provider, f.field, count(*) as n
      from fields f
     group by f.provider, f.field
     order by f.provider, count(*) desc, f.field
  )
  select s.provider,
         count(*) as reviewed,
         count(*) filter (where s.corrected is not null) as corrected,
         -- The share accepted as read. Two places, because the
         -- difference between 94% and 94.4% is not a decision anybody
         -- makes and a longer figure invites one.
         round(100.0 * count(*) filter (where s.corrected is null)
               / nullif(count(*), 0), 2) as accuracy,
         w.field, w.n
    from seen s
    left join worst w on w.provider = s.provider
   group by s.provider, w.field, w.n
   order by count(*) desc, s.provider;
$$;

comment on function public.platform_scan_accuracy(integer) is
  'Per reader: readings a person checked, readings they had to change, '
  'the share accepted as read, and the field each reader gets wrong '
  'most. The answer to whether a cheaper reader is actually cheaper. '
  'Empty for a non-admin rather than an exception. 0684.';

revoke all on function public.platform_scan_accuracy(integer)
  from public, anon;
grant execute on function public.platform_scan_accuracy(integer)
  to authenticated;
