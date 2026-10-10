-- =====================================================================
-- iAkauntan :: 0793 a share link is the database's
--
-- `0094` lets a company send a customer a link to an invoice. The link
-- is issued by `share_document` -- the token handed back once, only its
-- hash kept -- and `open_shared_document` records each opening: "that
-- somebody tried is worth as much as that somebody read it". Its own
-- comment says what the table's one write policy was for:
--
--     Members may see and revoke their organization's links.
--
-- But `document_share_links_update` grants an UPDATE of every column
-- to any member who may write, and revoking has gone through
-- `revoke_document_share` since. The app only reads the table. Measured
-- on 10 October 2026, locally, as a member with the accountant's role:
-- a link revoked because it had gone to the wrong address was revived,
-- given a fifty-year life, and pointed at ANOTHER customer's invoice,
-- and its opened record -- the time, the count, the address -- was set
-- to whatever the member chose. The holder of the old link then read
-- the other customer's invoice.
--
-- Answered "guard it like 0792". A trigger refuses a client's own
-- statement -- role `authenticated` or `anon`, at the top trigger depth
-- -- that changes a share link's document, token, expiry, opened record,
-- author or issue time, or clears or moves a revocation. Revoking a
-- live link by hand and correcting the address it was sent to stay the
-- company's. Clients cannot insert or delete these rows at all (no
-- privilege), so only the update is asked. The five functions that
-- write the table are SECURITY DEFINER and run as their owner, so they
-- pass. NOT security definer itself.
--
-- Production held no share link on 10 October.
-- =====================================================================

create or replace function app.share_link_is_the_databases()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_col  text;
  v_old  jsonb;
  v_new  jsonb;
  v_what text;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array[
      'org_id', 'document_id', 'token_hash', 'expires_at', 'opened_at',
      'last_opened_at', 'open_count', 'ip_address', 'user_agent',
      'created_by', 'created_at'] loop
    if (v_new -> v_col) is distinct from (v_old -> v_col) then
      v_what := case v_col
        when 'org_id' then 'company'
        when 'document_id' then 'document'
        when 'token_hash' then 'token'
        when 'expires_at' then 'expiry'
        when 'opened_at' then 'first opening'
        when 'last_opened_at' then 'last opening'
        when 'open_count' then 'count of openings'
        when 'ip_address' then 'opening address'
        when 'user_agent' then 'opening browser'
        when 'created_by' then 'author'
        when 'created_at' then 'issue time'
        else v_col end;
      raise exception
        'The % on a share link is the database''s to write, not a '
        'client''s.', v_what
        using errcode = '42501';
    end if;
  end loop;

  -- Revoking a live link by hand is the company's to do; bringing one
  -- back, or re-dating its revocation, is not.
  if old.revoked_at is not null
     and new.revoked_at is distinct from old.revoked_at then
    raise exception
      'A revoked share link stays revoked. Share the document again.'
      using errcode = '42501';
  end if;

  return new;
end $$;

revoke all on function app.share_link_is_the_databases() from public, anon, authenticated;

comment on function app.share_link_is_the_databases() is
  'Refuses a client''s own statement that writes a share link''s '
  'document, token, expiry, opened record, author or issue time, or '
  'brings a revoked link back. Revoking a live link and correcting its '
  'address stay allowed; the share functions run as their owner and '
  'pass. 0793.';

create trigger share_link_is_the_databases
  before update on public.document_share_links
  for each row execute function app.share_link_is_the_databases();
