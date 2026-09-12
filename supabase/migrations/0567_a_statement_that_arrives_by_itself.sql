-- =====================================================================
-- iAkauntan :: 0567 a statement that arrives by itself
--
-- `docs/gaps-against-autocount.md` has one row left in its "still
-- nothing at all" table: a bank feed. AutoCount Cloud syncs Maybank SME
-- and UOB Business directly; this has CSV import into bank
-- reconciliation, which the same document is careful to call a
-- different promise.
--
-- ---------------------------------------------------------------------
-- What is already here, and it is most of it
--
-- `import_bank_transactions` is feed-ready and nobody wrote it that
-- way on purpose. It refuses a line whose running balance does not
-- follow the one before it, and it skips a line already stored --
-- keyed on date, amount, description, reference AND balance, with the
-- balance in the key precisely so two identical withdrawals on one day
-- both import while the same line pasted twice does not.
--
-- That is the property a feed needs and a CSV upload does not. A person
-- chooses a date range and uploads it once. A feed re-delivers
-- overlapping windows forever, and an import without that key would
-- double every transaction in the overlap -- silently, and discovered
-- at reconciliation, which is the worst place to discover it.
--
-- So this migration does NOT touch the import. What it adds is what a
-- feed needs around it: somewhere to hold the connection, somewhere to
-- hold the secret that cannot be read back, and a record of every pull
-- so a feed that has stopped is visible before a month-end.
--
-- ---------------------------------------------------------------------
-- No connector is written here, and that is deliberate
--
-- There is no Maybank or UOB API access in the environment this was
-- built in, no credentials and no sandbox. A connector written against
-- a guessed response shape would be worse than none: it would look
-- finished, and the first thing anybody knew would be a statement
-- imported wrongly.
--
-- What is built is the half that can be asserted without a bank. The
-- connector is one edge function reading `bank_feeds`, calling
-- `import_bank_transactions` with what it fetched, and calling
-- `record_bank_feed_run` either way.
--
-- ---------------------------------------------------------------------
-- The secret, held the way `0107` and `0412` hold theirs
--
-- A bank feed credential reads somebody's bank statements, which puts
-- it in the same class as an acquirer key and an LHDN private key.
-- Those live in tables with RLS enabled and NO POLICIES AT ALL, every
-- privilege revoked from `anon` and `authenticated`, written through a
-- definer function guarded by `can_admin`, and read back only as "is
-- one set". Two barriers, both of which have to fail before a secret is
-- readable by anybody holding the publishable key -- and that key ships
-- in the web bundle.
--
-- Same shape here, down to the two barriers.
-- =====================================================================

create table if not exists public.bank_feeds (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations (id)
                    on delete cascade,
  -- One feed per account. A company banks in several places and each
  -- account connects on its own; a feed per company would be a feed
  -- that cannot express that.
  bank_account_id   uuid not null unique
                    references public.bank_accounts (id) on delete cascade,

  -- Named generically. `0412` made the same choice for forty-odd
  -- acquirers and for the same reason: the providers do not agree on
  -- vocabulary, and a column called `maybank_client_id` is a column
  -- that is wrong for every other bank.
  provider          text not null,
  api_key           text,
  api_secret        text,
  account_ref       text,

  status            text not null default 'connected'
                    check (status in ('connected', 'paused', 'failed',
                                      'revoked')),
  -- How far the feed has read. A cursor rather than a date where the
  -- provider gives one, because two statements can share a date and a
  -- date is not a position.
  cursor            text,
  last_pulled_at    timestamptz,
  last_error        text,

  created_by        uuid references auth.users (id),
  updated_by        uuid references auth.users (id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

comment on table public.bank_feeds is
  'A bank connection for one account. Holds a credential that can read '
  'somebody''s statements, so it is guarded the way einvoice_credentials '
  'and org_payment_gateways are: RLS on, no policies, nothing granted. '
  '0567.';

-- The first barrier. Enabled and left with NO POLICIES, which is what
-- `0107` does: a table with RLS on and nothing permitting is a table
-- that answers nothing to anybody but the owner and the service role.
alter table public.bank_feeds enable row level security;

-- The second. `0165`'s event trigger does this for functions; a table
-- needs it said.
revoke all on public.bank_feeds from anon, authenticated;

create index if not exists bank_feeds_org_idx on public.bank_feeds (org_id);

-- `0521`'s rule: a table with its own org_id naming a row in a table
-- with one too has to say which company's row it means.
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'bank_feeds_account_same_org') then
    alter table public.bank_feeds
      add constraint bank_feeds_account_same_org
      foreign key (org_id, bank_account_id)
      references public.bank_accounts (org_id, id)
      on delete cascade;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Every pull, whether or not it worked
--
-- The failure mode of a feed is not a wrong figure. It is silence: a
-- token expires, the pulls stop, nobody notices, and the gap is found
-- at month end by somebody trying to reconcile. `0552` made the demo
-- rebuild leave a row for the same reason -- a job with no record of
-- having run is a job nobody can tell has stopped.
-- ---------------------------------------------------------------------
create table if not exists public.bank_feed_runs (
  id          uuid primary key default gen_random_uuid(),
  feed_id     uuid not null references public.bank_feeds (id)
              on delete cascade,
  org_id      uuid not null references public.organizations (id)
              on delete cascade,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  ok          boolean not null default false,
  imported    integer not null default 0,
  -- Skipped is the number that says the feed is working. An overlapping
  -- window re-delivered should skip everything and import nothing, and
  -- a run that imports what it skipped last time is a duplicate problem
  -- announcing itself.
  skipped     integer not null default 0,
  error       text
);

comment on table public.bank_feed_runs is
  'One row per pull. A feed that has stopped is otherwise silent until '
  'somebody fails to reconcile. 0567.';

create index if not exists bank_feed_runs_feed_idx
  on public.bank_feed_runs (feed_id, started_at desc);

-- `0521`'s rule again, and this side of it is the one that needs the
-- key on the parent first. A run naming a feed of another company's
-- would be a pull recorded on the wrong books.
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'bank_feeds_org_id_id_key') then
    alter table public.bank_feeds
      add constraint bank_feeds_org_id_id_key unique (org_id, id);
  end if;

  if not exists (select 1 from pg_constraint
                  where conname = 'bank_feed_runs_feed_same_org') then
    alter table public.bank_feed_runs
      add constraint bank_feed_runs_feed_same_org
      foreign key (org_id, feed_id)
      references public.bank_feeds (org_id, id)
      on delete cascade;
  end if;
end $$;

alter table public.bank_feed_runs enable row level security;

-- Readable, unlike the feed itself: a run carries no secret, and
-- whether the bank feed is working is exactly what a bookkeeper needs
-- to know.
drop policy if exists bank_feed_runs_read on public.bank_feed_runs;
create policy bank_feed_runs_read on public.bank_feed_runs
  for select to authenticated
  using (app.can_read_ledger(org_id) or app.can_write(org_id));

revoke all on public.bank_feed_runs from anon;
grant select on public.bank_feed_runs to authenticated;

-- ---------------------------------------------------------------------
-- Connecting one
--
-- A null secret means "leave the one that is there", which is `0412`'s
-- rule and matters more here than it looks: a screen that cannot read
-- the key back has to be able to save the rest of the row without
-- sending it, and a form that sent an empty box as an empty key would
-- silently disconnect the feed on every save.
-- ---------------------------------------------------------------------
create or replace function public.connect_bank_feed(
  p_bank_account_id uuid,
  p_provider text,
  p_api_key text default null,
  p_api_secret text default null,
  p_account_ref text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_org      uuid;
  v_provider text := nullif(btrim(coalesce(p_provider, '')), '');
begin
  select org_id into v_org from public.bank_accounts
   where id = p_bank_account_id;
  if v_org is null then
    raise exception 'Bank account % not found', p_bank_account_id
      using errcode = 'P0002';
  end if;

  -- The same guard the credential tables use. Connecting a feed hands
  -- a third party a reader on the company's bank statements, which is
  -- not an ordinary bookkeeping act.
  if not app.can_admin(v_org) then
    raise exception 'Only an owner or administrator can connect a bank feed'
      using errcode = '42501';
  end if;

  if v_provider is null then
    raise exception 'Name the bank this feed reads' using errcode = '22023';
  end if;

  insert into public.bank_feeds (
    org_id, bank_account_id, provider, api_key, api_secret, account_ref,
    created_by, updated_by)
  values (
    v_org, p_bank_account_id, v_provider,
    nullif(btrim(coalesce(p_api_key, '')), ''),
    nullif(btrim(coalesce(p_api_secret, '')), ''),
    nullif(btrim(coalesce(p_account_ref, '')), ''),
    auth.uid(), auth.uid())
  on conflict (bank_account_id) do update
     set provider    = excluded.provider,
         -- Null leaves what is stored. The screen cannot read these
         -- back, so an empty box means "unchanged" and never "clear".
         api_key     = coalesce(excluded.api_key, bank_feeds.api_key),
         api_secret  = coalesce(excluded.api_secret, bank_feeds.api_secret),
         account_ref = coalesce(excluded.account_ref, bank_feeds.account_ref),
         -- Re-entering a credential is how somebody fixes a feed that
         -- failed, so saving one clears the failure rather than leaving
         -- a screen that says it is broken after it was mended.
         status      = case when bank_feeds.status = 'failed'
                             and excluded.api_key is not null
                            then 'connected' else bank_feeds.status end,
         last_error  = case when bank_feeds.status = 'failed'
                             and excluded.api_key is not null
                            then null else bank_feeds.last_error end,
         updated_by  = auth.uid(),
         updated_at  = now();
end;
$$;

comment on function public.connect_bank_feed(uuid, text, text, text, text) is
  'Connect or re-credential a bank feed. A null secret leaves the '
  'stored one alone, because the screen cannot read it back. 0567.';

revoke all on function public.connect_bank_feed(uuid, text, text, text, text)
  from public, anon;
grant execute on function public.connect_bank_feed(uuid, text, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- What a screen may know about it
--
-- Everything except the secret. `has_api_key` rather than the key is
-- `0412`'s answer and the only one that lets a screen say "connected"
-- without the key crossing the wire.
-- ---------------------------------------------------------------------
create or replace function public.bank_feed_status(p_bank_account_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_org  uuid;
  v_feed public.bank_feeds;
  v_run  public.bank_feed_runs;
begin
  select org_id into v_org from public.bank_accounts
   where id = p_bank_account_id;
  if v_org is null or not app.is_org_member(v_org) then
    return null;
  end if;

  select * into v_feed from public.bank_feeds
   where bank_account_id = p_bank_account_id;
  if not found then
    return null;
  end if;

  select * into v_run from public.bank_feed_runs
   where feed_id = v_feed.id order by started_at desc limit 1;

  return jsonb_build_object(
    'provider',       v_feed.provider,
    'status',         v_feed.status,
    -- Whether one is set, never what it is.
    'has_api_key',    v_feed.api_key is not null,
    'has_api_secret', v_feed.api_secret is not null,
    'account_ref',    v_feed.account_ref,
    'last_pulled_at', v_feed.last_pulled_at,
    'last_error',     v_feed.last_error,
    'last_run', case when v_run.id is null then null else jsonb_build_object(
      'started_at', v_run.started_at,
      'finished_at', v_run.finished_at,
      'ok', v_run.ok,
      'imported', v_run.imported,
      'skipped', v_run.skipped,
      'error', v_run.error) end);
end;
$$;

comment on function public.bank_feed_status(uuid) is
  'What a screen may know about a feed: everything except the secret. '
  '0567.';

revoke all on function public.bank_feed_status(uuid) from public, anon;
grant execute on function public.bank_feed_status(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Stopping one
--
-- Two different acts, and a single "delete" would hide the difference.
-- Pausing keeps the credential and stops pulling, which is what a
-- company does while it sorts something out. Disconnecting removes the
-- credential, which is what it does when it leaves the bank -- and the
-- row stays, so the runs behind it stay readable.
-- ---------------------------------------------------------------------
create or replace function public.set_bank_feed_paused(
  p_bank_account_id uuid,
  p_paused boolean
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_org uuid;
begin
  select b.org_id into v_org
    from public.bank_feeds f
    join public.bank_accounts b on b.id = f.bank_account_id
   where f.bank_account_id = p_bank_account_id;
  if v_org is null then
    raise exception 'There is no feed on that account' using errcode = 'P0002';
  end if;
  if not app.can_admin(v_org) then
    raise exception 'Only an owner or administrator can change a bank feed'
      using errcode = '42501';
  end if;

  update public.bank_feeds
     set status = case when p_paused then 'paused' else 'connected' end,
         last_error = case when p_paused then last_error else null end,
         updated_by = auth.uid(),
         updated_at = now()
   where bank_account_id = p_bank_account_id;
end;
$$;

revoke all on function public.set_bank_feed_paused(uuid, boolean)
  from public, anon;
grant execute on function public.set_bank_feed_paused(uuid, boolean)
  to authenticated;

create or replace function public.disconnect_bank_feed(p_bank_account_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_org uuid;
begin
  select b.org_id into v_org
    from public.bank_feeds f
    join public.bank_accounts b on b.id = f.bank_account_id
   where f.bank_account_id = p_bank_account_id;
  if v_org is null then
    raise exception 'There is no feed on that account' using errcode = 'P0002';
  end if;
  if not app.can_admin(v_org) then
    raise exception 'Only an owner or administrator can disconnect a bank feed'
      using errcode = '42501';
  end if;

  -- The credential goes; the row and its runs stay. What was imported
  -- and when is the company's record of where its statements came
  -- from, and deleting the feed would take it.
  update public.bank_feeds
     set status = 'revoked',
         api_key = null,
         api_secret = null,
         cursor = null,
         updated_by = auth.uid(),
         updated_at = now()
   where bank_account_id = p_bank_account_id;
end;
$$;

revoke all on function public.disconnect_bank_feed(uuid) from public, anon;
grant execute on function public.disconnect_bank_feed(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What the worker writes back
--
-- Service role only. This is the one function that can set a feed
-- `failed`, and a client that could call it could make a working feed
-- look broken -- or, worse, mark a failed one fine.
-- ---------------------------------------------------------------------
create or replace function public.record_bank_feed_run(
  p_feed_id uuid,
  p_ok boolean,
  p_imported integer default 0,
  p_skipped integer default 0,
  p_error text default null,
  p_cursor text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_feed public.bank_feeds;
  v_id   uuid;
begin
  select * into v_feed from public.bank_feeds where id = p_feed_id;
  if not found then
    raise exception 'There is no such feed' using errcode = 'P0002';
  end if;

  insert into public.bank_feed_runs
    (feed_id, org_id, finished_at, ok, imported, skipped, error)
  values (p_feed_id, v_feed.org_id, now(), p_ok,
          coalesce(p_imported, 0), coalesce(p_skipped, 0),
          nullif(btrim(coalesce(p_error, '')), ''))
  returning id into v_id;

  update public.bank_feeds
     set last_pulled_at = now(),
         last_error = case when p_ok then null
                           else nullif(btrim(coalesce(p_error, '')), '') end,
         -- A paused or revoked feed that somehow pulled is not moved
         -- back to connected by its own worker.
         status = case
                    when status in ('paused', 'revoked') then status
                    when p_ok then 'connected'
                    else 'failed'
                  end,
         cursor = coalesce(p_cursor, cursor),
         updated_at = now()
   where id = p_feed_id;

  return v_id;
end;
$$;

comment on function public.record_bank_feed_run(
  uuid, boolean, integer, integer, text, text) is
  'Written by the feed worker under the service role, and by nothing '
  'else: a client that could call this could make a working feed look '
  'broken, or a broken one look fine. 0567.';

revoke all on function public.record_bank_feed_run(
  uuid, boolean, integer, integer, text, text) from public, anon, authenticated;
grant execute on function public.record_bank_feed_run(
  uuid, boolean, integer, integer, text, text) to service_role;

-- ---------------------------------------------------------------------
-- And both tables wake the screens looking at them
--
-- `0547` attaches three statement triggers to every table carrying an
-- `org_id`, and `live_change_feed.sql` asserts the rule for the whole
-- schema rather than for a list -- so a table added afterwards fails
-- that file until it joins, which is what happened here.
--
-- Safe on `bank_feeds` despite the credential on it: `note_live_change`
-- writes the company and the table name and nothing else. What travels
-- is "something about your bank feeds changed", which is what a screen
-- needs and is not a secret.
-- ---------------------------------------------------------------------
do $$
declare v_table text;
begin
  foreach v_table in array array['bank_feeds', 'bank_feed_runs'] loop
    execute format(
      'drop trigger if exists live_change_insert on public.%I', v_table);
    execute format(
      'create trigger live_change_insert after insert on public.%I '
      'referencing new table as new_rows '
      'for each statement execute function app.note_live_change()',
      v_table);

    execute format(
      'drop trigger if exists live_change_update on public.%I', v_table);
    execute format(
      'create trigger live_change_update after update on public.%I '
      'referencing new table as new_rows old table as old_rows '
      'for each statement execute function app.note_live_change()',
      v_table);

    execute format(
      'drop trigger if exists live_change_delete on public.%I', v_table);
    execute format(
      'create trigger live_change_delete after delete on public.%I '
      'referencing old table as old_rows '
      'for each statement execute function app.note_live_change()',
      v_table);
  end loop;
end $$;
