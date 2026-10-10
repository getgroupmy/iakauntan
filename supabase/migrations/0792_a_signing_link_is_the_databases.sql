-- =====================================================================
-- iAkauntan :: 0792 a signing link is the database's
--
-- `0070` lets a director sign without an account, through a link the
-- secretary sends. `corp_create_signing_link` issues it -- one live
-- link per signature, the old one retired, never longer than ninety
-- days -- `corp_open_signing_link` records that it was opened ("the
-- only evidence the link reached anybody"), and `corp_sign_with_link`
-- marks it used. A signature made that way records no login: "the link
-- is the attribution, and it is recorded beside it".
--
-- `0791` guarded the signatures and the requests. The links sit beside
-- them under the same policy, `corp_signing_links_write`: `ALL` to any
-- member who may write. Measured on 10 October 2026, locally, as a
-- member with the accountant's role: a link retired because it had gone
-- to the wrong address was revived (`revoked_at` cleared), given a
-- hundred-year expiry, and its "opened" evidence set to a date and an
-- address of the member's choosing. Then, with no login at all, that
-- link signed the director's line.
--
-- Answered "guard it too". The same rule as `0791`: a trigger refuses a
-- client's own statement -- role `authenticated` or `anon`, at the top
-- trigger depth -- that inserts a link (`corp_create_signing_link`
-- issues them), changes a link's signature, token, expiry, use, opened
-- evidence, author or creation, clears or moves a retirement, or
-- deletes a link that was opened or used. Two things stay the
-- company's: retiring a live link by hand, and correcting the address
-- it was sent to. The three link functions are SECURITY DEFINER and run
-- as their owner, so they pass. NOT security definer itself.
--
-- The app and the edge functions write this table only through those
-- functions. Production held no signing link on 10 October.
-- =====================================================================

create or replace function app.signing_link_is_the_databases()
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
    return coalesce(new, old);
  end if;

  if tg_op = 'INSERT' then
    raise exception
      'Signing links are issued with corp_create_signing_link, which keeps '
      'one live link per signature and no link longer than ninety days.'
      using errcode = '42501';
  end if;

  if tg_op = 'DELETE' then
    if old.used_at is not null or old.opened_at is not null then
      raise exception
        'A link that was % is the record of it, and is not deleted. Retire '
        'it instead.',
        case when old.used_at is not null then 'used to sign' else 'opened' end
        using errcode = '42501';
    end if;
    return old;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array[
      'org_id', 'signature_id', 'token_hash', 'expires_at', 'used_at',
      'opened_at', 'ip_address', 'user_agent', 'created_by',
      'created_at'] loop
    if (v_new -> v_col) is distinct from (v_old -> v_col) then
      v_what := case v_col
        when 'org_id' then 'company'
        when 'signature_id' then 'signature'
        when 'token_hash' then 'token'
        when 'expires_at' then 'expiry'
        when 'used_at' then 'time of use'
        when 'opened_at' then 'opening time'
        when 'ip_address' then 'opening address'
        when 'user_agent' then 'opening browser'
        when 'created_by' then 'author'
        when 'created_at' then 'issue time'
        else v_col end;
      raise exception
        'The % on a signing link is the database''s to write, not a '
        'client''s.', v_what
        using errcode = '42501';
    end if;
  end loop;

  -- Retiring a live link by hand is the company's to do; bringing one
  -- back, or re-dating its retirement, is not.
  if old.revoked_at is not null
     and new.revoked_at is distinct from old.revoked_at then
    raise exception
      'A retired signing link stays retired. Issue a new one.'
      using errcode = '42501';
  end if;

  return new;
end $$;

revoke all on function app.signing_link_is_the_databases() from public, anon, authenticated;

comment on function app.signing_link_is_the_databases() is
  'Refuses a client''s own statement that issues a signing link, writes '
  'its signature, token, expiry, use, opened evidence, author or issue '
  'time, brings a retired link back, or deletes one that was opened or '
  'used. Retiring a live link and correcting its address stay allowed; '
  'the link functions run as their owner and pass. 0792.';

create trigger signing_link_is_the_databases
  before insert or update or delete on public.corp_signing_links
  for each row execute function app.signing_link_is_the_databases();
