-- =====================================================================
-- iAkauntan :: 0685 what a reader keeps saying
--
-- `0680` gave the console a scan log: every scan, newest first, with
-- the reason the failed ones failed. Fifty rows at a time, filterable
-- by status and searchable by reference.
--
-- That answers "what happened to THIS scan", which is the question
-- somebody asks when they are holding a reference number. It does not
-- answer the other question, which is the one nobody can currently ask
-- at all:
--
--     Does this reader ever work?
--
-- Answering it today means paging through the log by eye and counting.
-- There is no provider filter on it and no grouping, so a reader that
-- has failed on every scan since the day it was switched on looks
-- exactly like a reader that failed twice last Tuesday.
--
-- ---------------------------------------------------------------------
-- The case this exists for
--
-- `0675` added Gemini as `kind = 'openai'`, which routes it through the
-- chat-completions path with `strict: true`, `max_completion_tokens`
-- and `additionalProperties: false` on nested objects. Google's
-- OpenAI-compatibility layer is a compatibility layer, not the same
-- API, and it is not obliged to take all three.
--
-- Nothing in this repository has ever proven a Gemini scan came back
-- schema-shaped. It might be working perfectly. It might have been
-- answering 400 to every request since the day it was switched on, and
-- the symptom -- "The document could not be read" with a reference --
-- is the same sentence this function says about everything, which is
-- precisely why it was chosen. `0679`'s fallback then quietly carries
-- the scan to another reader, so the tenant gets their document and
-- the platform pays twice and nobody is told.
--
-- That is not a question to answer by reading a vendor's documentation
-- and hoping. It is a question to answer by looking at what the vendor
-- actually said, which is already stored, in `ocr_scans.error`, on
-- every failed row.
--
-- ---------------------------------------------------------------------
-- Why the message has to be normalised first
--
-- Grouping on the raw text gives one group per scan. Vendor errors
-- carry ids, request references and quoted fragments of the payload:
--
--   Invalid JSON payload received. Unknown name "strict" at
--   'response_format.json_schema': Cannot find field. [request 4f3c...]
--
-- Two of those are the same fault and different strings. So they are
-- reduced to a SHAPE -- ids, hex blobs and quoted contents replaced,
-- whitespace collapsed -- and counted by that.
--
-- What is deliberately NOT normalised is a short number. `HTTP 400`
-- and `HTTP 429` are a schema the vendor rejected and a quota you ran
-- out of, and those want different people doing different things. Only
-- runs of six digits or more go, because those are references rather
-- than facts.
-- =====================================================================

create or replace function app.scan_error_shape(p_error text)
returns text
language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select nullif(left(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(lower(coalesce(p_error, '')),
              -- A uuid, in any of the places a vendor puts one.
              '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
              '<id>', 'g'),
          -- A long hex blob: a request id, a trace, a key fingerprint.
          '\m[0-9a-f]{12,}\M', '<id>', 'g'),
        -- Six digits or more is a reference. Four hundred is a fact,
        -- and the difference between 400 and 429 is the difference
        -- between a schema this code sent wrongly and a quota somebody
        -- has to go and raise.
        '\m[0-9]{6,}\M', '<n>', 'g'),
      -- A LONG quoted run is a fragment of the payload echoed back and
      -- differs on every request. A short one is the fault itself --
      -- `Unknown name "strict"` names the field the vendor rejected,
      -- which is the single most useful word in the message and the
      -- only thing distinguishing it from `Unknown name
      -- "max_completion_tokens"`. Replacing both merged two different
      -- faults into one line, which the assertions caught.
      '"[^"]{40,}"', '"…"', 'g'),
    -- And whatever spacing the vendor wrapped it at.
    '\s+', ' ', 'g'), 300), '');
$$;

comment on function app.scan_error_shape(text) is
  'A vendor error reduced to what is repeatable about it: ids, hex '
  'blobs, long numbers and quoted payload fragments replaced, spacing '
  'collapsed. Short numbers are KEPT, because HTTP 400 and HTTP 429 '
  'are different problems for different people. 0685.';

-- ---------------------------------------------------------------------
-- The report
--
-- One row per reader and distinct fault. `read` and `failed` are the
-- reader's totals for the window and repeat down its rows, so the row
-- itself says whether this is a reader with an occasional problem or a
-- reader that has never once worked.
--
-- Guard in the WHERE clause rather than a raise, as `platform_scan_log`
-- settled on in `0680` and `platform_scan_accuracy` in `0684`: a
-- non-admin gets no rows, and a console that asks this while a session
-- is being downgraded draws an empty table instead of throwing.
-- ---------------------------------------------------------------------
create or replace function public.platform_reader_failures(
  p_days integer default 30)
returns table (
  provider      text,
  provider_name text,
  read          bigint,
  failed        bigint,
  fault         text,
  n             bigint,
  first_seen    timestamptz,
  last_seen     timestamptz,
  example_ref   text)
language sql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
  with win as (
    select s.*
      from public.ocr_scans s
     where app.is_platform_admin()
       and s.created_at > now() - make_interval(days => greatest(p_days, 1))
  ), totals as (
    select w.provider,
           count(*) filter (where w.status = 'ok') as read,
           count(*) filter (where w.status = 'failed') as failed
      from win w
     group by w.provider
  ), faults as (
    select w.provider,
           app.scan_error_shape(w.error) as fault,
           count(*) as n,
           min(w.created_at) as first_seen,
           max(w.created_at) as last_seen,
           -- One reference, so an operator can go and read the whole
           -- row in the scan log rather than only the summary.
           (array_agg(w.log_ref order by w.created_at desc)
              filter (where w.log_ref is not null))[1] as example_ref
      from win w
     where w.status = 'failed'
     group by w.provider, app.scan_error_shape(w.error)
  )
  select f.provider,
         coalesce(pr.name, f.provider),
         t.read, t.failed,
         coalesce(f.fault, '(no message recorded)'),
         f.n, f.first_seen, f.last_seen, f.example_ref
    from faults f
    join totals t on t.provider = f.provider
    left join public.ocr_providers pr on pr.code = f.provider
   -- A reader that has never once succeeded first, then by how loud
   -- the fault is. That ordering is the point: the row at the top is
   -- the reader somebody switched on and has been paying for.
   order by (t.read = 0) desc, f.n desc, f.provider, f.fault;
$$;

comment on function public.platform_reader_failures(integer) is
  'Per reader and distinct fault: how often, when it started, when it '
  'last happened, and one reference to look up. Carries the reader''s '
  'read and failed totals on every row, so a reader that has NEVER '
  'succeeded is visible as that rather than as a long list of '
  'individually unremarkable failures. Readers that have never '
  'succeeded sort first. Empty for a non-admin. 0685.';

revoke all on function public.platform_reader_failures(integer)
  from public, anon;
grant execute on function public.platform_reader_failures(integer)
  to authenticated;
