-- ---------------------------------------------------------------------
-- A retry that does not post twice
--
-- ## The defect, demonstrated rather than assumed
--
-- `post_manual_journal` called twice with byte-identical arguments
-- returns two different ids and leaves two `gl_entries` behind. That was
-- checked against this schema before this migration was written, and
-- `manual_journal.sql` now holds it as an assertion.
--
-- It is the shape of every write that *creates* something. A client
-- POSTs, the response is lost to a dropped connection or a timeout, the
-- client retries because it cannot know whether the first one landed —
-- and the ledger, which is append-only by design, now carries the entry
-- twice. Somebody reverses one by hand.
--
-- ## What is NOT affected, and why that matters
--
-- The `post_*(p_id uuid)` family — `post_sales_document`,
-- `post_receipt`, `post_purchase_payment` and the rest — is already
-- safe, and not by luck: `app.post_sales_document_internal` refuses a
-- document whose `gl_entry_id` is already set. A retry there raises
-- "Document X is already posted" rather than posting twice. The state is
-- the guard, and the document is the natural idempotency key.
--
-- So this migration is deliberately not applied to them. Wrapping a
-- function that cannot double-post buys nothing and costs a signature
-- somebody has to maintain. What it does buy, and what those functions
-- still lack, is a retry that returns the *original answer* instead of
-- an error — worth having, not worth conflating with a correctness fix.
--
-- ## The mechanism
--
-- A claimed key, then a stored result. `app.idempotency_begin` either
-- returns null, meaning "you are the first, go and do the work", or
-- returns the result of the call that already did it. The caller does
-- the work and hands the answer to `app.idempotency_end`.
--
-- Three refusals are built in.
--
-- *A key reused for a different request* is a client bug, and silently
-- returning the first answer would hide it. The arguments are
-- fingerprinted and a mismatch raises `22023`. `md5` is enough: this
-- detects a mistake, it does not defend against an adversary who
-- already holds the key.
--
-- *A key still in flight* raises `55006`. Two concurrent requests with
-- one key means the client sent the retry before the first finished;
-- the honest answer is "ask again", not a second execution.
--
-- *No key at all* is allowed, and does nothing. Every existing caller —
-- the Flutter client, the schedulers, the cascades — passes none and
-- keeps exactly today's behaviour. That is why the original functions
-- are left untouched and the key arrives on an overload instead: no
-- existing signature changes, so nothing already asserted can shift
-- under the change.
--
-- ## Scoping
--
-- The key is unique per organization, not globally. Two tenants that
-- both generate "1" are two different requests, and a key is only ever
-- honoured for the company it was claimed under.
--
-- Retention is 24 hours, swept by `app.run_daily_jobs`. A key older
-- than that is not a retry, it is a new request.
--
-- ## The key must not be given a default
--
-- PostgREST resolves an overloaded function by matching the parameter
-- names in the request body against each candidate's parameter names.
-- `p_idempotency_key` having no default is what keeps that
-- unambiguous: a body without it matches only the original, a body
-- with it matches only the wrapper.
--
-- Adding `default null` here would make both overloads match a body
-- that omits the key, and PostgREST would refuse the call as
-- ambiguous — breaking the existing client, which sends no key. It
-- reads like a tidy-up and it is a breaking change.
-- ---------------------------------------------------------------------

create table if not exists public.idempotency_keys (
  org_id       uuid not null references public.organizations (id) on delete cascade,
  key          text not null check (length(key) between 1 and 255),
  operation    text not null,
  fingerprint  text not null,
  user_id      uuid references auth.users (id),
  status       text not null default 'in_progress'
               check (status in ('in_progress', 'completed')),
  result       jsonb,
  created_at   timestamptz not null default now(),
  completed_at timestamptz,
  primary key (org_id, key)
);

create index if not exists idempotency_keys_created_idx
  on public.idempotency_keys (created_at);

comment on table public.idempotency_keys is
  'Claimed idempotency keys and the results of the calls that claimed '
  'them, so a retried write returns the original answer instead of '
  'doing the work again. 24 hour retention, swept daily. Never read by '
  'the client: 0307 revokes it and the app.* functions reach it as '
  'SECURITY DEFINER.';

alter table public.idempotency_keys enable row level security;

-- No policy, and the grants taken back explicitly. Supabase's default
-- privileges hand every new table to anon and authenticated whatever
-- the migration asked for — 0299 exists because of exactly that — so
-- silence here would be a table the client could read and write. The
-- only way in is the SECURITY DEFINER functions below.
revoke all on public.idempotency_keys from anon, authenticated;

create or replace function app.idempotency_fingerprint(p_args jsonb)
returns text
language sql
immutable
-- Pinned like every other function here. `search_path.sql` asserts it,
-- and caught this one being written without it.
set search_path = public, app, pg_temp
as $$
  -- `jsonb` already normalises key order, so two argument sets that
  -- differ only in how the client serialised them fingerprint the same.
  select md5(coalesce(p_args, '{}'::jsonb)::text)
$$;

create or replace function app.idempotency_begin(
  p_org_id uuid, p_key text, p_operation text, p_args jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_fp  text := app.idempotency_fingerprint(p_args);
  v_row public.idempotency_keys;
begin
  -- No key: the caller is not asking for idempotency and gets today's
  -- behaviour exactly.
  if p_key is null or btrim(p_key) = '' then
    return null;
  end if;

  insert into public.idempotency_keys
    (org_id, key, operation, fingerprint, user_id)
  values (p_org_id, btrim(p_key), p_operation, v_fp, auth.uid())
  on conflict (org_id, key) do nothing;

  if found then
    return null;              -- first through: go and do the work
  end if;

  select * into v_row from public.idempotency_keys
   where org_id = p_org_id and key = btrim(p_key);

  if v_row.operation <> p_operation or v_row.fingerprint <> v_fp then
    raise exception
      'Idempotency key % was already used for a different request',
      btrim(p_key) using errcode = '22023';
  end if;

  if v_row.status = 'in_progress' then
    raise exception
      'Idempotency key % is still in progress', btrim(p_key)
      using errcode = '55006';
  end if;

  return coalesce(v_row.result, 'null'::jsonb);
end;
$$;

create or replace function app.idempotency_end(
  p_org_id uuid, p_key text, p_result jsonb)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  if p_key is null or btrim(p_key) = '' then
    return;
  end if;
  update public.idempotency_keys
     set status = 'completed', result = p_result, completed_at = now()
   where org_id = p_org_id and key = btrim(p_key);
end;
$$;

create or replace function app.sweep_idempotency_keys(p_before timestamptz)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_n integer;
begin
  delete from public.idempotency_keys where created_at < p_before;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------
-- The wrappers
--
-- One overload per protected function, taking the key as a trailing
-- argument. The original is called unchanged, so everything already
-- asserted about it still holds.
-- ---------------------------------------------------------------------

create or replace function public.post_manual_journal(
  p_org_id uuid, p_entry_date date, p_lines jsonb, p_description text,
  p_reference text, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_seen jsonb; v_id uuid;
begin
  v_seen := app.idempotency_begin(p_org_id, p_idempotency_key,
    'post_manual_journal',
    jsonb_build_object('entry_date', p_entry_date, 'lines', p_lines,
                       'description', p_description, 'reference', p_reference));
  if v_seen is not null then
    return nullif(v_seen ->> 'id', '')::uuid;
  end if;

  v_id := public.post_manual_journal(p_org_id, p_entry_date, p_lines,
                                     p_description, p_reference);
  perform app.idempotency_end(p_org_id, p_idempotency_key,
                              jsonb_build_object('id', v_id));
  return v_id;
end;
$$;

create or replace function public.create_contra(
  p_org uuid, p_date date, p_invoices jsonb, p_bills jsonb, p_notes text,
  p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_seen jsonb; v_id uuid;
begin
  v_seen := app.idempotency_begin(p_org, p_idempotency_key, 'create_contra',
    jsonb_build_object('date', p_date, 'invoices', p_invoices,
                       'bills', p_bills, 'notes', p_notes));
  if v_seen is not null then
    return nullif(v_seen ->> 'id', '')::uuid;
  end if;

  v_id := public.create_contra(p_org, p_date, p_invoices, p_bills, p_notes);
  perform app.idempotency_end(p_org, p_idempotency_key,
                              jsonb_build_object('id', v_id));
  return v_id;
end;
$$;

create or replace function public.create_deposit(
  p_org uuid, p_kind text, p_contact uuid, p_date date, p_amount numeric,
  p_bank uuid, p_mode text, p_reference text, p_notes text,
  p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_seen jsonb; v_id uuid;
begin
  v_seen := app.idempotency_begin(p_org, p_idempotency_key, 'create_deposit',
    jsonb_build_object('kind', p_kind, 'contact', p_contact, 'date', p_date,
                       'amount', p_amount, 'bank', p_bank, 'mode', p_mode,
                       'reference', p_reference, 'notes', p_notes));
  if v_seen is not null then
    return nullif(v_seen ->> 'id', '')::uuid;
  end if;

  v_id := public.create_deposit(p_org, p_kind, p_contact, p_date, p_amount,
                                p_bank, p_mode, p_reference, p_notes);
  perform app.idempotency_end(p_org, p_idempotency_key,
                              jsonb_build_object('id', v_id));
  return v_id;
end;
$$;

create or replace function public.record_pdc(
  p_org uuid, p_direction text, p_contact uuid, p_cheque_no text,
  p_cheque_date date, p_amount numeric, p_documents jsonb, p_bank uuid,
  p_bank_name text, p_received date, p_notes text, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_seen jsonb; v_id uuid;
begin
  v_seen := app.idempotency_begin(p_org, p_idempotency_key, 'record_pdc',
    jsonb_build_object('direction', p_direction, 'contact', p_contact,
                       'cheque_no', p_cheque_no, 'cheque_date', p_cheque_date,
                       'amount', p_amount, 'documents', p_documents,
                       'bank', p_bank, 'bank_name', p_bank_name,
                       'received', p_received, 'notes', p_notes));
  if v_seen is not null then
    return nullif(v_seen ->> 'id', '')::uuid;
  end if;

  v_id := public.record_pdc(p_org, p_direction, p_contact, p_cheque_no,
                            p_cheque_date, p_amount, p_documents, p_bank,
                            p_bank_name, p_received, p_notes);
  perform app.idempotency_end(p_org, p_idempotency_key,
                              jsonb_build_object('id', v_id));
  return v_id;
end;
$$;

-- 0165's event trigger strips PUBLIC and anon from every new function;
-- a grant to `authenticated` survives a replace, but these are new.
grant execute on function public.post_manual_journal(
  uuid, date, jsonb, text, text, text) to authenticated;
grant execute on function public.create_contra(
  uuid, date, jsonb, jsonb, text, text) to authenticated;
grant execute on function public.create_deposit(
  uuid, text, uuid, date, numeric, uuid, text, text, text, text) to authenticated;
grant execute on function public.record_pdc(
  uuid, text, uuid, text, date, numeric, jsonb, uuid, text, date, text, text)
  to authenticated;

revoke all on function app.idempotency_begin(uuid, text, text, jsonb)
  from public, anon, authenticated;
revoke all on function app.idempotency_end(uuid, text, jsonb)
  from public, anon, authenticated;
revoke all on function app.sweep_idempotency_keys(timestamptz)
  from public, anon, authenticated;
