-- =====================================================================
-- iAkauntan :: 0785 the address on the record is the caller's
--
-- Fifteen functions record where a request came from -- the audit
-- trail, payslip reads, document signatures, signing and share links
-- among them -- and every one of them does it the same way:
--
--     nullif(split_part(coalesce(
--       app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet
--
-- the FIRST hop of X-Forwarded-For, cast to an address. Two things were
-- wrong with that, measured on 9 October 2026:
--
--   * A first hop that is not an address breaks the write it is
--     recorded on. Locally, `X-Forwarded-For: unknown, 203.0.113.9` --
--     which some corporate proxies send -- made an ordinary contact save
--     fail with "invalid input syntax for type inet". Everybody behind
--     such a proxy could save nothing that is audited.
--
--   * The first hop is whatever the CLIENT sent. Cloudflare, in front
--     of the hosted project, appends the address it saw after any
--     X-Forwarded-For the request already carried. So the address on an
--     audit row, and on a signature made through a link -- recorded as
--     evidence of who signed -- was the caller's to choose.
--
-- Every request in production's gateway log on 9 October carried
-- `cf-connecting-ip`, which Cloudflare sets from the connection and
-- does not take from the client; Supabase's own guidance reads it where
-- the address has to be trusted.
--
-- Answered "cf-connecting-ip, never fail". The fifteen callers all ask
-- `app.request_header('x-forwarded-for')`, so the fix is made there,
-- once: asked for that header, it now answers with the caller's
-- ADDRESS -- `cf-connecting-ip` if it is one, else the first hop of
-- X-Forwarded-For that is one, else nothing -- written as a bare
-- address the callers' own split and cast take unchanged. A malformed
-- header now records no address rather than refusing the write. Every
-- other header is answered as before.
--
-- One side effect, checked rather than assumed: `0165`'s event trigger
-- strips PUBLIC's EXECUTE from every function a migration creates, a
-- replacement included, so after this only the owner may call it. On 9
-- October every caller was a SECURITY DEFINER function owned by the
-- same role, and no policy, view, invoker function or client called it,
-- so nothing loses anything. `client_address.sql` asserts it stays so.
--
-- Restated from `0047`, whose text production runs exactly (identical
-- source hash on 9 October). Production's audit trail held 1,526 rows
-- with an address in the 30 days before, from 8 addresses, none of them
-- private; this changes how the next row's address is chosen, not any
-- row already written.
-- =====================================================================

create or replace function app.request_header(p_name text)
returns text language plpgsql stable
set search_path = pg_catalog, pg_temp as $$
declare
  v_headers json;
  v_hop     text;
begin
  begin
    v_headers := current_setting('request.headers', true)::json;
  exception when others then
    return null;
  end;

  if p_name is distinct from 'x-forwarded-for' then
    return nullif(v_headers ->> p_name, '');
  end if;

  -- `0785`. The caller's address rather than the header: the one
  -- Cloudflare saw first, then the first hop that IS an address, then
  -- nothing. Never an error -- an address nobody can read is not a
  -- reason to refuse what the caller was doing.
  foreach v_hop in array
      array[v_headers ->> 'cf-connecting-ip']
      || string_to_array(coalesce(v_headers ->> 'x-forwarded-for', ''), ',')
  loop
    v_hop := btrim(coalesce(v_hop, ''));
    continue when v_hop = '';
    begin
      return host(v_hop::inet);
    exception when invalid_text_representation then
      -- Not an address ('unknown', a host name, a port glued on): the
      -- next one is asked.
      null;
    end;
  end loop;

  return null;
end;
$$;

comment on function app.request_header(text) is
  'One header of the current API request, or null outside one. Asked '
  'for x-forwarded-for, answers with the CALLER''S ADDRESS instead of '
  'the header: cf-connecting-ip, which the edge sets and a client cannot, '
  'else the first X-Forwarded-For hop that is an address, else null -- '
  'never an error, so an unreadable header cannot refuse an audited '
  'write. 0785.';
