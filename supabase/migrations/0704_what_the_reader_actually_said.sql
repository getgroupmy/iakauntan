-- =====================================================================
-- iAkauntan :: 0704 what the reader actually said
--
-- Asked for from the console: "all scanning activities should be logged
-- and all error or reply by models should be logged in raw as this is
-- to be used for troubleshooting".
--
-- What the console could show was `ocr_scans.error` -- ONE SENTENCE,
-- written by us, out of whichever field of the vendor's JSON the edge
-- function thought to reach for. The screenshot that prompted this is
-- the whole argument:
--
--     Nothing was read. Gemini refused the document: This model is
--     currently experiencing high demand.
--
-- That is the vendor's sentence and it is a good one. The next reader
-- will answer something the code did not anticipate, and then the
-- sentence is `HTTP 400` and the body that would have explained it is
-- gone -- read once inside the reader and dropped.
--
-- ---------------------------------------------------------------------
-- Every call, not every failure
--
-- A scan is not one call. `0679` gives a failed reader a free fallback
-- and `459d3716` retries a "not now" once inside the same invocation,
-- so one scan row can stand for three requests to two vendors, and
-- until now which of them said what was unanswerable. Each is a row
-- here, in order.
--
-- And the SUCCESSFUL ones are kept too, which is the half somebody
-- will be tempted to drop. A reading that came back wrong -- `Page 1 of
-- 2` in the supplier name, a total off by a factor of ten -- is the
-- case where the raw reply matters most, and by definition it did not
-- fail.
--
-- ---------------------------------------------------------------------
-- What is NOT in here, and why it cannot be
--
-- The REQUEST. No headers, no body. `x-api-key`, `Authorization:
-- Bearer` and Gemini's `?key=` live there, and the surest way not to
-- log a key is never to be handed one: `supabase/functions/ocr/
-- exchange.ts` records the response and the endpoint with its QUERY
-- STRING STRIPPED, and nothing else. The document's own bytes are in
-- the request too, so not keeping it also keeps a megabyte of base64
-- out of every row.
--
-- ---------------------------------------------------------------------
-- Who may read it
--
-- The platform, and nobody else. A tenant can already read its own
-- `ocr_scans` rows through RLS, and this table deliberately does not
-- work that way: RLS is on with NO policy for `authenticated`, so the
-- only way in is `platform_scan_exchanges`, which is `security definer`
-- and guarded by `app.is_platform_admin()`.
--
-- That is not caution for its own sake. A vendor's failure quotes the
-- project, the processor and sometimes the page it choked on -- `0111`
-- keeps exactly that out of the tenant's response -- and a successful
-- reply contains the document. The console is where both belong.
--
-- ---------------------------------------------------------------------
-- And it is thrown away again
--
-- 30 days, purged weekly. Raw bodies are the largest thing this system
-- would keep and troubleshooting is a thing somebody does within days
-- of a report, not a year later. A log with no end is a table nobody
-- notices until it is the reason a backup takes an hour.
-- =====================================================================

-- The composite key below needs somewhere to point. `ocr_scans` is
-- keyed by `id` alone, which is enough to name a scan and not enough to
-- name a scan ON A COMPANY -- and the second is what
-- `tenant_foreign_keys.sql` requires of every table that carries an
-- `org_id`. Its rule found this within a minute of the table existing.
alter table public.ocr_scans
  drop constraint if exists ocr_scans_org_id_id_key;
alter table public.ocr_scans
  add constraint ocr_scans_org_id_id_key unique (org_id, id);

create table if not exists public.ocr_exchanges (
  id          uuid primary key default gen_random_uuid(),

  -- Named TOGETHER, below, as one key into `ocr_scans (org_id, id)`.
  -- Separately they would be two facts that can disagree: a row could
  -- carry this company's `org_id` and that company's `scan_id`, and
  -- every guard here reads the `org_id`. The same shape `0702` records
  -- for `ocr_scans.attachment_id`, and for the same reason.
  scan_id     uuid not null,
  org_id      uuid not null,

  at          timestamptz not null default now(),

  -- 1 is the first attempt, 2 the retry, 3 the fallback. In order, and
  -- the order is the point.
  attempt     smallint not null default 1,

  -- The reader that was called, as a catalog code. Text and not a
  -- foreign key: a reader retired out of the catalog must not take the
  -- history of what it said with it.
  provider    text,

  -- Scheme, host and path. NEVER the query -- see the header.
  endpoint    text,

  -- 0 means nothing answered at all, which is a different fault from
  -- answering no and the console could not tell them apart before.
  http_status integer,
  ms          integer,
  ok          boolean not null default false,

  -- The reply, verbatim, up to 16k.
  body        text,
  truncated   boolean not null default false,

  -- Cascaded, so a scan that goes takes its exchanges with it. There is
  -- nothing to say about a call whose scan no longer exists.
  constraint ocr_exchanges_scan_same_org
    foreign key (org_id, scan_id)
    references public.ocr_scans (org_id, id) on delete cascade,

  constraint ocr_exchanges_org
    foreign key (org_id) references public.organizations (id)
    on delete cascade
);

alter table public.ocr_exchanges enable row level security;

-- No policy for `authenticated`, deliberately. See the header: this is
-- the platform's view and the only door is the function below.
comment on table public.ocr_exchanges is
  'What each reader actually answered, raw, one row per call -- so a '
  'retry and a fallback are two more rows on the same scan. Response '
  'only: no request, no headers, no key, and the endpoint with its '
  'query string stripped. Platform administrators only, and purged '
  'after 30 days. 0704.';

create index if not exists ocr_exchanges_scan_idx
  on public.ocr_exchanges (scan_id, attempt);
create index if not exists ocr_exchanges_at_idx
  on public.ocr_exchanges (at);

-- ---------------------------------------------------------------------
-- The door in, for the edge function
-- ---------------------------------------------------------------------
--
-- One call with a jsonb array rather than a row at a time: the whole
-- scan's exchanges are known at once and three round trips to record
-- three calls would be three chances to lose one.
--
-- The service role alone. Nothing a tenant can reach writes here, so
-- nothing a tenant can reach can put words in a reader's mouth.
create or replace function public.ocr_record_exchanges(
  p_scan_id   uuid,
  p_exchanges jsonb)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org uuid;
  v_n   integer := 0;
begin
  if p_exchanges is null or jsonb_typeof(p_exchanges) <> 'array' then
    return 0;
  end if;

  select s.org_id into v_org from public.ocr_scans s where s.id = p_scan_id;
  -- Not an exception. This is a log written after the work, and a scan
  -- that has been deleted between the reading and the recording is not
  -- a reason to turn a successful scan into a failed function.
  if v_org is null then
    return 0;
  end if;

  insert into public.ocr_exchanges
    (scan_id, org_id, attempt, provider, endpoint, http_status, ms, ok,
     body, truncated)
  select p_scan_id,
         v_org,
         -- The order of the array IS the order of the calls.
         (ord)::smallint,
         nullif(e ->> 'provider', ''),
         nullif(e ->> 'endpoint', ''),
         nullif(e ->> 'status', '')::integer,
         nullif(e ->> 'ms', '')::integer,
         coalesce((e ->> 'ok')::boolean, false),
         e ->> 'body',
         coalesce((e ->> 'truncated')::boolean, false)
    from jsonb_array_elements(p_exchanges) with ordinality as t(e, ord);

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

comment on function public.ocr_record_exchanges(uuid, jsonb) is
  'Records what the readers answered on one scan, in the order they '
  'were called. The service role alone -- nothing a tenant reaches can '
  'put words in a reader''s mouth. Answers 0 rather than raising when '
  'the scan has gone: this is a log written after the work, and losing '
  'it must not turn a successful scan into a failed function. 0704.';

revoke all on function public.ocr_record_exchanges(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.ocr_record_exchanges(uuid, jsonb)
  to service_role;

-- ---------------------------------------------------------------------
-- The door in, for the console
-- ---------------------------------------------------------------------
--
-- The guard is in the WHERE clause, the way `platform_scan_log`'s is
-- and for the reason its comment gives: this is a list, and a screen
-- that 500s is not more secure than one that is empty.
create or replace function public.platform_scan_exchanges(p_scan_id uuid)
returns table (
  id          uuid,
  at          timestamptz,
  attempt     smallint,
  provider    text,
  endpoint    text,
  http_status integer,
  ms          integer,
  ok          boolean,
  body        text,
  truncated   boolean)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select e.id, e.at, e.attempt, e.provider, e.endpoint, e.http_status,
         e.ms, e.ok, e.body, e.truncated
    from public.ocr_exchanges e
   where app.is_platform_admin()
     and e.scan_id = p_scan_id
   order by e.attempt, e.at;
$$;

comment on function public.platform_scan_exchanges(uuid) is
  'Everything the readers said on one scan, raw and in order. Platform '
  'administrators only; anybody else gets no rows. 0704.';

revoke all on function public.platform_scan_exchanges(uuid)
  from public, anon;
grant execute on function public.platform_scan_exchanges(uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- And thrown away again
-- ---------------------------------------------------------------------
create or replace function app.purge_ocr_exchanges(p_days integer default 30)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_n integer;
begin
  delete from public.ocr_exchanges
   where at < now() - make_interval(days => greatest(1, coalesce(p_days, 30)));
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

comment on function app.purge_ocr_exchanges(integer) is
  'Drops raw reader replies older than p_days. Troubleshooting happens '
  'within days of a report; a log with no end is a table nobody notices '
  'until it is the reason a backup takes an hour. 0704.';

revoke all on function app.purge_ocr_exchanges(integer)
  from public, anon, authenticated;

-- Its own job rather than a line in `run_daily_jobs`, for the reason
-- `0235`'s purge gives: a purge that fails must not be able to take
-- anything else with it, and one that runs a day late costs nothing.
do $do$
begin
  if exists (select 1 from cron.job
              where jobname = 'iakauntan-purge-ocr-exchanges') then
    perform cron.unschedule('iakauntan-purge-ocr-exchanges');
  end if;
  perform cron.schedule(
    'iakauntan-purge-ocr-exchanges',
    '45 19 * * 0',
    $job$select app.purge_ocr_exchanges(30)$job$);
end
$do$;
