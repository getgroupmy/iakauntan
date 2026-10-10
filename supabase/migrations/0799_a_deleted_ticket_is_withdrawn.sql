-- =====================================================================
-- iAkauntan :: 0799 a deleted ticket is withdrawn
--
-- `0390` gave a ticket's share link a state, `app.ticket_link_state`,
-- read by `open_shared_ticket` and `reply_to_shared_ticket`, both of
-- which a customer calls with no login. It answers 'withdrawn' for a
-- ticket that is gone or cancelled, and never asked whether it was
-- deleted -- `tickets.deleted_at`, which the SLA sweep and the dashboard
-- both read as gone. Measured on 10 October 2026, locally: a ticket
-- deleted after its link went out; the link still opened, showing the
-- subject, the description and every visible comment, and still took a
-- customer's reply, onto a ticket nobody at the company can see. The app
-- deletes no ticket; a write through the API does.
--
-- Answered "withdrawn, like cancelled". A deleted ticket's link answers
-- 'withdrawn': it shows nothing and takes no reply, as the invoice and
-- portal links answer for a deleted document or customer. Otherwise
-- restated from `0390` (production's body hashes identically,
-- 4d4b82bc...). Still executable by its owner alone.
--
-- Production held thirteen tickets, none deleted, and no ticket link,
-- on 10 October.
-- =====================================================================

create or replace function app.ticket_link_state(
  p_token text, out link_id uuid, out state text)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  l public.ticket_share_links;
  t public.tickets;
begin
  select * into l from public.ticket_share_links
   where token_hash = app.corp_token_hash(p_token);
  if l.id is null then
    link_id := null; state := 'invalid'; return;
  end if;

  select * into t from public.tickets where id = l.ticket_id;
  link_id := l.id;
  state := case
    when l.revoked_at is not null then 'revoked'
    when l.expires_at < now() then 'expired'
    when t.id is null or t.deleted_at is not null then 'withdrawn'
    when t.status = 'cancelled' then 'withdrawn'
    else 'open'
  end;
end $$;

revoke all on function app.ticket_link_state(text) from public, anon, authenticated;

comment on function app.ticket_link_state(text) is
  'The state of a ticket''s share link: invalid, revoked, expired, '
  'withdrawn (the ticket gone, cancelled or deleted) or open. Read by '
  'open_shared_ticket and reply_to_shared_ticket. 0799.';
