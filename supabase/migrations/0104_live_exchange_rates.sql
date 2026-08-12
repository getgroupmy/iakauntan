-- =====================================================================
-- iAkauntan :: 0104 the day's rates, fetched rather than typed
--
-- `exchange_rates` has been in the schema since 0002 and every row in it
-- has been typed by a person. That is not merely tedious. Since 0083,
-- `revalue_foreign_balances` refuses a currency it cannot price — it
-- raises P0002 rather than assuming par, deliberately, because assuming
-- 1 would write nearly the whole balance off as an exchange loss. So a
-- month-end revaluation is blocked until somebody remembers to enter a
-- closing rate for every currency on the book. The safety check and the
-- empty table together mean the revaluation quietly does not happen.
--
-- Two things had been left in place for this and never used. `org_id` on
-- `exchange_rates` is nullable, and the select policy in 0010 reads
-- `org_id is null or app.is_org_member(org_id)` — so a row belonging to
-- nobody is already readable by everybody. And `source` has carried
-- `check (source in ('manual', 'bnm', 'api'))` since the beginning.
-- Whoever wrote 0002 meant a central feed to land here.
--
-- ---------------------------------------------------------------------
-- Which rate wins
--
-- A fetched rate never touches an organization's own row. The feed only
-- ever writes `org_id is null`, and the org's row wins whenever both
-- exist for the same date. That ordering is the whole safety argument:
-- a rate somebody typed is a deliberate act, it may already have priced
-- a posted document, and a nightly job must not be able to move it.
--
-- What the feed does do is fill the gaps. Ask for the 15th with an org
-- rate on the 1st and a published rate on the 15th, and the published
-- one is used — because the org's 1 March rate says what the rate was on
-- 1 March, not that 1 March's rate should apply forever. The precedence
-- is therefore *by date first, then by whose row it is*, which is one
-- `order by` and reads exactly as the rule is stated.
--
-- An organization whose base currency is not the ringgit gets nothing
-- from a feed quoting in ringgit, and keeps typing. That is correct
-- rather than a limitation to fix: the fallback only matches rows whose
-- `to_currency` is that organization's base.
--
-- ---------------------------------------------------------------------
-- Where the arithmetic lives
--
-- Bank Negara quotes some currencies per 100 units — the yen, the won,
-- the rupiah — and one per unit. Divide by the wrong number and the yen
-- is wrong by a factor of a hundred, in a figure that balances and looks
-- plausible on a page. That division is therefore done here, in SQL,
-- where `supabase/tests/exchange_rate_feed.sql` asserts it, and not in
-- the edge function where nothing in CI would ever run it. The function
-- passes the published quote and its unit through unchanged and does no
-- arithmetic at all.
--
-- Nothing here makes a network call. `supabase/functions/fetch-rates` is
-- the transport, for the same reason `send-email` is: the database does
-- not wait on a third party, and no key belonging to a third party is
-- ever in it. Scheduling that function is a deployment step, written up
-- in the README.
-- =====================================================================

-- ---------------------------------------------------------------------
-- One published rate per currency per day
--
-- The table's `unique (org_id, from_currency, to_currency, rate_date)`
-- does not constrain these rows at all: in a UNIQUE constraint two NULLs
-- are distinct, so every run of the feed would insert a *second* row for
-- the same day rather than conflicting with the first. Within a week the
-- lookup's `order by` would be choosing between duplicates by nothing at
-- all. A partial index over the rows where `org_id is null` is what
-- actually makes the feed idempotent, and it is what the insert below
-- infers its conflict target from.
-- ---------------------------------------------------------------------
create unique index if not exists exchange_rates_system_uk
  on public.exchange_rates (from_currency, to_currency, rate_date)
  where org_id is null;

-- ---------------------------------------------------------------------
-- The rate to apply, now with somewhere to fall back to
--
-- 0078's body, with two changes: system rows are in scope, and the
-- `order by` states the precedence. Everything else — latest on or
-- before the date, raise rather than default to 1, refuse a rate that is
-- not positive — is unchanged and still the point of the function.
-- ---------------------------------------------------------------------
create or replace function app.exchange_rate_for(
  p_org_id uuid, p_currency character, p_on_date date)
returns numeric
language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_base character(3) := app.base_currency(p_org_id);
  v_rate numeric(18, 8);
begin
  if p_currency is null or p_currency = v_base then
    return 1;
  end if;

  select rate into v_rate
    from public.exchange_rates
   where (org_id = p_org_id or org_id is null)
     and from_currency = p_currency
     and to_currency = v_base
     and rate_date <= p_on_date
   -- Newest first; where an organization's own rate and a published one
   -- share a date, the organization's wins.
   order by rate_date desc, (org_id is not null) desc
   limit 1;

  if v_rate is null then
    raise exception
      'No exchange rate for % to % on or before %. Enter one before posting.',
      p_currency, v_base, p_on_date
      using errcode = 'P0002';
  end if;

  if v_rate <= 0 then
    raise exception 'Exchange rate for % on % is %, which cannot be used.',
      p_currency, p_on_date, v_rate using errcode = '23514';
  end if;

  return v_rate;
end;
$$;

-- ---------------------------------------------------------------------
-- Taking delivery of a published quote
--
-- Shaped like `import_contacts`: one row of verdict per row in, so the
-- caller can log what happened rather than guess from a count. Unlike
-- the importers this is *not* all-or-nothing — a central bank dropping
-- one currency from its list is not a reason to refuse the other twenty,
-- and each rate stands alone in a way the rows of an import do not.
--
-- `p_rows` carries the published figures unchanged:
--   [{"currency_code":"JPY","unit":100,"rate":2.8,"rate_date":"2026-08-11"}]
--
-- `rate_date` is the date the quote belongs to, taken from the payload
-- rather than from the clock. A Sunday run of a feed that publishes on
-- business days therefore rewrites Friday's row with Friday's figure
-- instead of inventing a Sunday rate, and running twice in a day changes
-- nothing the second time.
-- ---------------------------------------------------------------------
create or replace function public.ingest_exchange_rates(
  p_rows jsonb,
  p_source text default 'bnm',
  p_quote character default 'MYR')
-- The output columns are named away from the table's own — `quoted_on`
-- and `applied_rate` rather than `rate_date` and `rate`. A RETURNS TABLE
-- column is a plpgsql variable, and one sharing a name with a column of
-- the table being written is substituted into the statement: the ON
-- CONFLICT target below would infer against a variable instead of the
-- index. `import_contacts` was written twice for this reason, once with
-- an output column called `code` and once without.
returns table (
  currency     text,
  quoted_on    date,
  applied_rate numeric,
  status       text,
  message      text)
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r         jsonb;
  v_code    text;
  v_unit    numeric;
  v_quoted  numeric;
  v_on      date;
  v_rate    numeric(18, 8);
begin
  if p_source not in ('bnm', 'api') then
    raise exception 'A fetched rate must be sourced bnm or api, not %', p_source
      using errcode = '23514';
  end if;

  if not exists (select 1 from public.ref_currencies rc where rc.code = p_quote) then
    raise exception 'Unknown quote currency %', p_quote using errcode = '23503';
  end if;

  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array' then
    raise exception 'Rates must arrive as a JSON array, not a %',
      jsonb_typeof(p_rows) using errcode = '22023';
  end if;

  for r in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    currency := null; quoted_on := null; applied_rate := null;
    status   := 'error'; message := null;

    -- Held as text, not character(3). A feed that sends a four-letter
    -- code would fail the assignment itself if this were char(3), and
    -- take the whole batch down instead of reporting one bad row.
    v_code   := upper(nullif(trim(r ->> 'currency_code'), ''));
    v_unit   := nullif(r ->> 'unit', '')::numeric;
    v_quoted := nullif(r ->> 'rate', '')::numeric;
    v_on     := nullif(r ->> 'rate_date', '')::date;

    currency  := v_code;
    quoted_on := v_on;

    if v_code is null or v_quoted is null or v_on is null then
      message := 'currency_code, rate and rate_date are all required';
      return next; continue;
    end if;

    if length(v_code) <> 3 then
      message := format('%L is not a three-letter currency code', v_code);
      return next; continue;
    end if;

    -- Absent rather than 1. A feed that has stopped sending `unit` is a
    -- feed whose shape has changed underneath us, and guessing at it is
    -- how the yen ends up wrong by a hundred.
    if v_unit is null or v_unit <= 0 then
      message := format('unit is %s; it must be a positive number of units '
                        'the quote is given for', coalesce(v_unit::text, 'missing'));
      return next; continue;
    end if;

    if v_quoted <= 0 then
      message := format('a rate of %s cannot be used', v_quoted);
      return next; continue;
    end if;

    if v_code = p_quote then
      status  := 'skipped';
      message := 'a currency does not need a rate against itself';
      return next; continue;
    end if;

    -- Not an error. A feed carries what its publisher lists, and this
    -- system carries the currencies it has been told about; the overlap
    -- is not either party's mistake. Inserting anyway would fail the
    -- foreign key and take the rest of the batch with it.
    if not exists (
      select 1 from public.ref_currencies rc
       where rc.code = v_code and rc.is_active) then
      status  := 'skipped';
      message := 'not a currency this system holds';
      return next; continue;
    end if;

    v_rate := round(v_quoted / v_unit, 8);

    -- Only reachable for a currency quoted so finely that eight decimal
    -- places cannot hold it. Better said out loud than stored as zero,
    -- which the column's own check would refuse anyway.
    if v_rate <= 0 then
      message := format('%s per %s units rounds to nothing at eight decimals',
                        v_quoted, v_unit);
      return next; continue;
    end if;

    insert into public.exchange_rates
      (org_id, from_currency, to_currency, rate, rate_date, source)
    values (null, v_code::character(3), p_quote, v_rate, v_on, p_source)
    on conflict (from_currency, to_currency, rate_date) where org_id is null
      do update set rate = excluded.rate, source = excluded.source;

    applied_rate := v_rate;
    status := 'stored';
    message := case
      when v_unit = 1 then null
      else format('quoted per %s units', trim(to_char(v_unit, 'FM999999')))
    end;
    return next;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- What rate is actually in force, and where it came from
--
-- The lookup answers one currency at a time and says nothing about
-- provenance, which is fine for pricing a document and useless for
-- answering "why is this the rate?". This returns the row the lookup
-- would choose for each currency the organization could use, with the
-- date and the source attached, so a screen can show a typed rate and a
-- published one as the different things they are.
--
-- A currency with no rate at all comes back with a null rate rather than
-- being left out. "EUR — nothing on file" is the single most useful line
-- on this list: it is the one that will refuse to post on Friday.
-- ---------------------------------------------------------------------
create or replace function public.exchange_rate_board(
  p_org_id uuid, p_on_date date default current_date)
returns table (
  currency   character(3),
  name       text,
  rate       numeric,
  rate_date  date,
  source     text,
  is_own     boolean)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare v_base character(3);
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;
  v_base := app.base_currency(p_org_id);

  return query
  select c.code, c.name, e.rate, e.rate_date, e.source, e.org_id is not null
    from public.ref_currencies c
    left join lateral (
      select x.rate, x.rate_date, x.source, x.org_id
        from public.exchange_rates x
       where (x.org_id = p_org_id or x.org_id is null)
         and x.from_currency = c.code
         and x.to_currency = v_base
         and x.rate_date <= p_on_date
       order by x.rate_date desc, (x.org_id is not null) desc
       limit 1) e on true
   where c.is_active and c.code <> v_base
   order by c.code;
end;
$$;

-- ---------------------------------------------------------------------
-- Reachability
--
-- Postgres grants EXECUTE to PUBLIC on a new function, so every one of
-- these has to be taken away before it is given back — the lesson 0080
-- was written to fix.
--
-- The ingest is the one function in this migration that writes rows
-- every organization reads, and no signed-in user should be able to call
-- it however senior they are: a rate that prices everybody's ledger is
-- not an organization's business. It goes to `service_role` only, which
-- means the edge function and nothing else. The RLS insert policy in
-- 0010 already says the same thing from the other side — it requires
-- `org_id is not null` — so even a direct insert by a signed-in user
-- cannot create a system row.
-- ---------------------------------------------------------------------
revoke all on function public.ingest_exchange_rates(jsonb, text, character)
  from public, anon, authenticated;
grant execute on function public.ingest_exchange_rates(jsonb, text, character)
  to service_role;

revoke all on function public.exchange_rate_board(uuid, date)
  from public, anon;
grant execute on function public.exchange_rate_board(uuid, date)
  to authenticated, service_role;

revoke all on function app.exchange_rate_for(uuid, character, date)
  from public, anon;
grant execute on function app.exchange_rate_for(uuid, character, date)
  to authenticated, service_role;
