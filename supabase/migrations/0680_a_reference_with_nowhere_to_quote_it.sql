-- =====================================================================
-- iAkauntan :: 0680 a reference with nowhere to quote it
--
--     Could not read it: FunctionException(status: 502, details:
--     {error: The document could not be read. Quote this reference if
--     you get in touch., details: {ref: e5b6506c-..., scan_id:
--     6e50da40-..., refunded: false}})
--
-- reported from Bills, on a live scan. The sentence is right to be
-- vague -- `0111` keeps the vendor's own message out of the response
-- because a Document AI failure quotes the project, the processor and
-- sometimes the page it choked on. The real reason goes to
-- `ocr_scans.error`.
--
-- ---------------------------------------------------------------------
-- Where it goes, and who can read it
--
--     $ grep -rn "ocr_scans" app/lib --include=*.dart | wc -l
--     0
--
-- Nothing. Not the console, not Settings, not the screen the scan was
-- started from. The reference exists so somebody can look it up and
-- there was nowhere in the product to look it up -- so "get in touch"
-- resolved to hand-written SQL against production, by the same person
-- who was being told to get in touch.
--
-- ---------------------------------------------------------------------
-- And the reference itself could not be looked up AT ALL
--
-- Worse than a missing screen. `logFailure` mints `ref` with
-- `crypto.randomUUID()` and writes it to the function's stdout. It is
-- never stored. So of the two identifiers in that banner the one
-- labelled "quote this reference" was the one that could never be
-- resolved from the database, and the one that could -- `scan_id` --
-- is not the one the sentence points at.
--
-- `log_ref` below is that fix: the ref is written against the scan, so
-- the number somebody reads off a screenshot is the number that finds
-- the row. The edge function now mints it BEFORE settling rather than
-- after, which is the only change needed to have it in hand.
-- =====================================================================

alter table public.ocr_scans
  add column if not exists log_ref text;

comment on column public.ocr_scans.log_ref is
  'The reference quoted to whoever was scanning when this failed. Minted '
  'by `logFailure` in the edge function and written here so that the '
  'number on somebody''s screenshot finds this row -- until `0680` it '
  'went only to the function''s stdout, so the identifier the message '
  'told people to quote was the one nothing could look up.';

create index if not exists ocr_scans_log_ref_idx
  on public.ocr_scans (log_ref) where log_ref is not null;

create or replace function public.ocr_note_log_ref(
  p_scan_id uuid, p_ref text)
returns void
language sql security definer
set search_path = public, pg_temp as $$
  update public.ocr_scans set log_ref = p_ref where id = p_scan_id;
$$;

comment on function public.ocr_note_log_ref(uuid, text) is
  'Records against a scan the reference its failure was reported under. '
  'A separate call rather than another argument to `ocr_finish`, which '
  'several other things call and whose signature is not worth moving '
  'for this. The service role alone.';

revoke all on function public.ocr_note_log_ref(uuid, text)
  from public, anon, authenticated;
grant execute on function public.ocr_note_log_ref(uuid, text)
  to service_role;

-- ---------------------------------------------------------------------
-- The log itself
--
-- Joined rather than raw, because the three questions an operator has
-- are "whose", "on which reader" and "why", and two of those are names
-- in other tables. A screen that returned uuids would send them back to
-- SQL for the second half of the same question.
--
-- `p_search` takes either identifier off the banner -- the reference or
-- the scan id -- because the person pasting it should not have to know
-- which of the two the system can use. A prefix is enough: nobody types
-- out a uuid.
-- ---------------------------------------------------------------------
create or replace function public.platform_scan_log(
  p_limit  integer default 50,
  p_status text default null,
  p_search text default null)
returns table (
  id             uuid,
  log_ref        text,
  created_at     timestamptz,
  finished_at    timestamptz,
  org_id         uuid,
  org_name       text,
  provider       text,
  provider_name  text,
  key_source     text,
  status         text,
  amount_charged numeric,
  refunded       boolean,
  fell_back_to   text,
  file_name      text,
  error          text)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select s.id, s.log_ref, s.created_at, s.finished_at,
         s.org_id, o.name,
         s.provider, coalesce(pr.name, s.provider),
         s.key_source, s.status, s.amount_charged, s.refunded,
         s.fell_back_to,
         -- The last segment of the path. An operator wants to know
         -- which document, and the rest of the path is the org id and
         -- the table, both of which are already columns here.
         split_part(s.storage_path, '/', 4),
         s.error
    from public.ocr_scans s
    left join public.organizations o on o.id = s.org_id
    left join public.ocr_providers pr on pr.code = s.provider
   where app.is_platform_admin()
     and (p_status is null or s.status = p_status)
     and (p_search is null or btrim(p_search) = ''
          or s.id::text like btrim(lower(p_search)) || '%'
          or s.log_ref like btrim(lower(p_search)) || '%')
   order by s.created_at desc
   limit greatest(1, least(coalesce(p_limit, 50), 200));
$$;

comment on function public.platform_scan_log(integer, text, text) is
  'Every scan this platform has run, newest first, with the reason the '
  'failed ones failed -- which is kept out of the response the person '
  'scanning sees, because a vendor''s message quotes the project and '
  'the processor. Searchable by EITHER identifier off that message, '
  'the reference or the scan id, since somebody pasting one should not '
  'have to know which of the two can be looked up. Platform '
  'administrators only: the guard is in the WHERE clause, so a caller '
  'who is not one gets no rows rather than an exception -- this is a '
  'list, and a screen that 500s is not more secure than one that is '
  'empty.';

revoke all on function public.platform_scan_log(integer, text, text)
  from public, anon;
grant execute on function public.platform_scan_log(integer, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- The three numbers worth seeing before the list
--
-- `unsettled` is the one that matters. A scan still `pending` an hour
-- after it started is a function that died between `ocr_begin` and
-- `ocr_finish` -- so the charge was taken and never given back, which
-- `index.ts` already shouts about in its own log and which nothing has
-- ever counted.
-- ---------------------------------------------------------------------
create or replace function public.platform_scan_health()
returns jsonb
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select case when not app.is_platform_admin() then '{}'::jsonb else
    jsonb_build_object(
      'ok_24h', (select count(*) from public.ocr_scans
                  where status = 'ok' and created_at > now() - interval '24 hours'),
      'failed_24h', (select count(*) from public.ocr_scans
                      where status = 'failed' and created_at > now() - interval '24 hours'),
      'unsettled', (select count(*) from public.ocr_scans
                     where status = 'pending' and created_at < now() - interval '1 hour'),
      'unsettled_charged', (select coalesce(sum(amount_charged), 0)
                              from public.ocr_scans
                             where status = 'pending'
                               and created_at < now() - interval '1 hour'))
  end;
$$;

comment on function public.platform_scan_health() is
  'How scanning is going: read in the last day, failed in the last day, '
  'and the count and value of scans still pending an hour after they '
  'started. That last pair is money: a scan stuck pending is a function '
  'that died between `ocr_begin` and `ocr_finish`, so the charge was '
  'taken and the refund never ran. Platform administrators only, and an '
  'empty object rather than an exception for everybody else.';

revoke all on function public.platform_scan_health() from public, anon;
grant execute on function public.platform_scan_health() to authenticated;
