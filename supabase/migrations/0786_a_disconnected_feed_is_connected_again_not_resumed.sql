-- =====================================================================
-- iAkauntan :: 0786 a disconnected feed is connected again, not resumed
--
-- `0567` gave a bank feed three writers: connect (or re-credential),
-- pause or resume, and disconnect -- which drops the key, the secret
-- and the cursor and marks the feed 'revoked', keeping the row and its
-- runs. Two of the three disagreed about what comes after a
-- disconnect. Measured on 9 October 2026, locally:
--
--   * `connect_bank_feed` with a new key on a disconnected feed stored
--     the key and left the status 'revoked'. It re-arms only a 'failed'
--     feed, so a company that left its bank and came back could enter
--     its credentials and have a feed that never ran again, with
--     nothing to say why;
--   * `set_bank_feed_paused(false)` on the same feed marked it
--     'connected' with no key at all -- the runner would pick it up and
--     fail on every pull. Pausing it first, then resuming, got there
--     too.
--
-- Answered "fix now". A new key re-arms a disconnected feed as it
-- already re-armed a failed one. Pausing or resuming a disconnected
-- feed is refused, saying what to do instead: a disconnected feed is
-- neither running nor paused, and the way back is its key.
--
-- No connector exists yet, so no feed runs anywhere; production held no
-- feed on 9 October. This is the SQL `repository.dart` says is "ready
-- and waiting" made to be so. Restated from `0567`, whose text
-- production runs exactly (identical source hashes on 9 October). One
-- condition changes in the first function and one paragraph is new in
-- the second.
-- =====================================================================

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
         -- `0786`: and a new key is how a DISCONNECTED feed comes back,
         -- for the same reason -- it was left 'revoked' with the key in.
         status      = case when bank_feeds.status in ('failed', 'revoked')
                             and excluded.api_key is not null
                            then 'connected' else bank_feeds.status end,
         last_error  = case when bank_feeds.status in ('failed', 'revoked')
                             and excluded.api_key is not null
                            then null else bank_feeds.last_error end,
         updated_by  = auth.uid(),
         updated_at  = now();
end;
$$;

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

  -- `0786`. A disconnected feed has no key: resuming it would mark it
  -- running with nothing to run on, and pausing it first was the same
  -- road one step longer. The way back is its key.
  if exists (select 1 from public.bank_feeds f
              where f.bank_account_id = p_bank_account_id
                and f.status = 'revoked') then
    raise exception
      'That feed was disconnected. Connect it again with its key.'
      using errcode = '22023';
  end if;

  update public.bank_feeds
     set status = case when p_paused then 'paused' else 'connected' end,
         last_error = case when p_paused then last_error else null end,
         updated_by = auth.uid(),
         updated_at = now()
   where bank_account_id = p_bank_account_id;
end;
$$;

comment on function public.connect_bank_feed(uuid, text, text, text, text) is
  'Connect or re-credential a bank feed. A null secret leaves the '
  'stored one alone, because the screen cannot read it back. A new key '
  'brings back a feed that failed or was disconnected (`0786`). 0567.';

comment on function public.set_bank_feed_paused(uuid, boolean) is
  'Pauses or resumes the automatic statement feed on one bank account. '
  'Pausing stops new statement lines arriving; it does not disconnect '
  'the feed or discard what has already come in. A disconnected feed '
  'is neither, and is refused: it comes back by being connected with '
  'its key (`0786`). Needs `can_admin`.';
