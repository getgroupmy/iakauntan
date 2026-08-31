-- =====================================================================
-- iAkauntan :: the customer who could not reply to their own ticket
--
-- `0192` built `ticket_comments` with two author columns and a check
-- constraint saying exactly one of them must be filled:
--
--     constraint ticket_comments_one_author check (
--       (author_user_id is not null)::int
--       + (author_contact_id is not null)::int = 1)
--
-- `author_contact_id` has never been written. `add_ticket_comment`
-- always sets `author_user_id` to `auth.uid()`, and there is no other
-- writer anywhere. So the requester half of every conversation in this
-- helpdesk is unreachable: staff talk to each other on the ticket, and
-- the customer who raised it cannot say anything at all.
--
-- The `app.ticket_channel` enum has `email` and `web` in it for the
-- same reason and with the same result.
--
-- The mechanism for this is already built twice over. `0070` hands a
-- resolution to a director who is not staff, and `0094` hands an
-- invoice to a customer who has no login: a long random token, only its
-- hash stored, one live link at a time, an expiry, and the open
-- recorded because that is the only evidence the link reached anybody.
-- All of it applies here unchanged, so all of it is reused rather than
-- rewritten.
--
-- Three rules make this correct rather than merely possible.
--
-- **An internal note never leaves the building.** `is_internal` defaults
-- to true, and `0192`'s own comment calls it "the single most dangerous
-- boolean in a helpdesk". What the requester is shown is filtered on it,
-- and a reply they write is `false` unconditionally — not defaulted,
-- because a customer's message that landed as an internal note would be
-- invisible to the person it was sent to.
--
-- **A customer's message is not the company's first response.**
-- `add_ticket_comment` stops the first-response clock on the first
-- visible comment. If a requester's own reply did that, the SLA report
-- would show a target met that nobody met — the same falsehood shape as
-- `0385`'s discount and `0387`'s paid date: a control that appears to
-- have been applied. So it is written past deliberately, and the test
-- asserts the absence.
--
-- **A reply takes the ticket off the customer's hands.** `pending`
-- pauses the SLA clock, which is right while the company is waiting for
-- an answer and wrong the moment the answer arrives. A reply moves the
-- ticket back to `open` through `transition_ticket`, so the paused
-- minutes are added and the deadline moves exactly as they do when a
-- member does it by hand. A reply on a resolved or closed ticket
-- reopens it, which is what `tickets.reopened_count` is for.
-- =====================================================================

create table if not exists public.ticket_share_links (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id)
                  on delete cascade,
  ticket_id     uuid not null references public.tickets (id) on delete cascade,
  token_hash    text not null unique,
  expires_at    timestamptz not null,
  sent_to_email text,
  opened_at     timestamptz,
  last_opened_at timestamptz,
  open_count    integer not null default 0,
  reply_count   integer not null default 0,
  ip_address    inet,
  user_agent    text,
  revoked_at    timestamptz,
  created_by    uuid references auth.users (id),
  created_at    timestamptz not null default now()
);

create index if not exists ticket_share_links_ticket
  on public.ticket_share_links (ticket_id);

alter table public.ticket_share_links enable row level security;

-- Members may see and revoke their organization's links. Nobody writes
-- one directly: the token is returned to the caller exactly once and
-- never stored in the clear, which an insert policy cannot arrange.
drop policy if exists ticket_share_links_select on public.ticket_share_links;
create policy ticket_share_links_select on public.ticket_share_links
  for select to authenticated using (app.is_org_member(org_id));

drop policy if exists ticket_share_links_update on public.ticket_share_links;
create policy ticket_share_links_update on public.ticket_share_links
  for update to authenticated
  using (app.can_write(org_id)) with check (app.can_write(org_id));

-- ---------------------------------------------------------------------
-- Issue a link
--
-- Only for a ticket raised by a contact. A ticket whose requester is a
-- member of staff has a login already, and a link would be a second
-- door into a conversation they can reach through the front one.
-- ---------------------------------------------------------------------
create or replace function public.share_ticket(
  p_ticket uuid,
  p_valid_days integer default 30,
  p_email text default null)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  t public.tickets;
  v_token text;
begin
  select * into t from public.tickets where id = p_ticket;
  if t.id is null then
    raise exception 'No such ticket.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(t.org_id, 'ticketing') then
    raise exception 'not permitted to share a ticket' using errcode = '42501';
  end if;
  if t.requester_contact_id is null then
    raise exception
      'That ticket was raised by a member of staff, who can already read '
      'it. A link is for a requester with no login.'
      using errcode = '22023';
  end if;
  if t.status = 'cancelled' then
    raise exception 'A cancelled ticket is not shared.'
      using errcode = '22023';
  end if;

  v_token := app.corp_new_token();

  -- One live link per ticket, for `0094`'s reason: leaving the old one
  -- alive makes "revoke" mean nothing.
  update public.ticket_share_links
     set revoked_at = now()
   where ticket_id = p_ticket and revoked_at is null;

  insert into public.ticket_share_links
    (org_id, ticket_id, token_hash, expires_at, sent_to_email, created_by)
  values (t.org_id, p_ticket, app.corp_token_hash(v_token),
          now() + make_interval(
            days => greatest(least(coalesce(p_valid_days, 30), 365), 1)),
          nullif(btrim(p_email), ''), auth.uid());

  return v_token;
end $$;

create or replace function public.revoke_ticket_share(p_ticket uuid)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_org uuid; v_n integer;
begin
  select org_id into v_org from public.tickets where id = p_ticket;
  if v_org is null then
    raise exception 'No such ticket.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'ticketing') then
    raise exception 'not permitted to revoke a ticket link'
      using errcode = '42501';
  end if;

  update public.ticket_share_links
     set revoked_at = now()
   where ticket_id = p_ticket and revoked_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ---------------------------------------------------------------------
-- What the token resolves to
--
-- One place, so the reader and the writer cannot disagree about which
-- links are live. Returns the link row, or nothing.
-- ---------------------------------------------------------------------
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
    when t.id is null then 'withdrawn'
    when t.status = 'cancelled' then 'withdrawn'
    else 'open'
  end;
end $$;

-- ---------------------------------------------------------------------
-- Open a link
--
-- Callable by `anon`, which is why every field below was chosen. What
-- comes back is the ticket the requester raised and the part of the
-- conversation meant for them: no internal note, no assignee, no SLA
-- deadline, nothing about any other ticket and nothing about any other
-- customer.
--
-- An invalid token returns a state rather than an error, `0094`'s
-- reasoning unchanged: the alternative tells somebody guessing tokens
-- when they have found a real one.
-- ---------------------------------------------------------------------
create or replace function public.open_shared_ticket(p_token text)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  l public.ticket_share_links;
  v_link uuid;
  v_state text;
  t public.tickets;
  o public.organizations;
  c public.contacts;
begin
  select r.link_id, r.state into v_link, v_state
    from app.ticket_link_state(p_token) r;

  if v_state = 'invalid' then
    return jsonb_build_object('state', 'invalid');
  end if;
  select * into l from public.ticket_share_links where id = v_link;

  -- Recorded even when the answer is not 'open': that somebody tried is
  -- worth as much as that somebody read it.
  update public.ticket_share_links
     set opened_at = coalesce(opened_at, now()),
         last_opened_at = now(),
         open_count = open_count + 1,
         ip_address = coalesce(ip_address, nullif(split_part(coalesce(
           app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet),
         user_agent = coalesce(user_agent, app.request_header('user-agent'))
   where id = l.id;

  if v_state <> 'open' then
    return jsonb_build_object('state', v_state);
  end if;

  select * into t from public.tickets where id = l.ticket_id;
  select * into o from public.organizations where id = l.org_id;
  select * into c from public.contacts where id = t.requester_contact_id;

  return jsonb_build_object(
    'state', 'open',
    'company', jsonb_build_object(
      'name', coalesce(o.legal_name, o.name),
      'email', o.email,
      'phone', o.phone,
      'logo_url', o.logo_url),
    'contact', jsonb_build_object('name', c.name),
    'ticket', jsonb_build_object(
      'ticket_no', t.ticket_no,
      'subject', t.subject,
      'description', t.description,
      'status', t.status,
      'priority', t.priority,
      'created_at', t.created_at,
      'resolved_at', t.resolved_at,
      -- What the requester wrote when the ticket was resolved is
      -- addressed to them. The internal notes behind it are not.
      'resolution_note', t.resolution_note),
    'comments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'body', k.body,
               'created_at', k.created_at,
               -- Who said it, not which of our staff. A requester does
               -- not need the name of every agent who touched the file,
               -- and giving it away is a habit that ends in giving away
               -- more.
               'mine', k.author_contact_id is not null)
             order by k.created_at)
        from public.ticket_comments k
       where k.ticket_id = t.id
         -- The filter this whole function exists around.
         and not k.is_internal), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- The transition, without the permission check
--
-- `transition_ticket` asks `can_write_module`, which is right for a
-- member and impossible for a requester on a link. The body is the same
-- arithmetic — the paused minutes, the deadline shift, the reopen count
-- — and duplicating it here is how the two come to disagree about how
-- long a ticket was paused. So the guard moves out and the caller
-- carries it.
-- ---------------------------------------------------------------------
create or replace function app.transition_ticket_internal(
  p_ticket uuid, p_to app.ticket_status, p_note text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_t public.tickets;
  v_paused integer := 0;
  v_new_due timestamptz;
begin
  select * into v_t from public.tickets where id = p_ticket;
  if not found then
    raise exception 'No such ticket.' using errcode = 'P0002';
  end if;
  if v_t.status = p_to then return; end if;
  if not app.ticket_transition_allowed(v_t.status, p_to) then
    -- The refusal names what was available instead, because the useful
    -- part of "you cannot do that" is what you can do. Kept verbatim
    -- from `0194`: it is the message members already see.
    raise exception 'A ticket cannot go from % to %. Allowed from %: %',
      v_t.status, p_to, v_t.status,
      (select string_agg(x::text, ', ')
         from unnest(enum_range(null::app.ticket_status)) x
        where app.ticket_transition_allowed(v_t.status, x))
      using errcode = '22023';
  end if;

  v_new_due := v_t.resolution_due_at;
  if app.ticket_status_pauses_clock(v_t.status)
     and not app.ticket_status_pauses_clock(p_to)
     and v_t.paused_at is not null then
    v_paused := greatest(0,
      floor(extract(epoch from (now() - v_t.paused_at)) / 60)::integer);
    if v_paused > 0 and v_new_due is not null
       and v_t.sla_policy_id is not null then
      v_new_due := app.sla_advance(v_t.org_id, v_t.sla_policy_id,
                                   v_new_due, v_paused);
    end if;
  end if;

  update public.tickets
     set status = p_to,
         paused_at = case
           when app.ticket_status_pauses_clock(p_to)
                and not app.ticket_status_pauses_clock(v_t.status) then now()
           when not app.ticket_status_pauses_clock(p_to) then null
           else paused_at end,
         paused_minutes = paused_minutes + v_paused,
         resolution_due_at = v_new_due,
         resolved_at = case when p_to = 'resolved' then now()
                            when p_to in ('open','pending','on_hold') then null
                            else resolved_at end,
         closed_at = case when p_to = 'closed' then now()
                          when p_to = 'open' then null
                          else closed_at end,
         reopened_count = reopened_count
           + case when v_t.status in ('resolved','closed') and p_to = 'open'
                  then 1 else 0 end,
         resolution_note = coalesce(
           case when p_to in ('resolved','closed') then p_note else null end,
           resolution_note)
   where id = p_ticket;

  insert into public.ticket_events
    (org_id, ticket_id, event_type, from_value, to_value, note)
  values (v_t.org_id, p_ticket, 'status', v_t.status::text, p_to::text,
          p_note);
end $$;


-- The member's door, which is now the guard and a call.
create or replace function public.transition_ticket(
  p_ticket uuid, p_to app.ticket_status, p_note text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_org uuid;
begin
  select org_id into v_org from public.tickets where id = p_ticket;
  if v_org is null then
    raise exception 'Ticket % not found', p_ticket;
  end if;
  if not app.can_write_module(v_org, 'ticketing') then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  perform app.transition_ticket_internal(p_ticket, p_to, p_note);
end $$;

grant execute on function public.transition_ticket(
  uuid, app.ticket_status, text) to authenticated;

-- ---------------------------------------------------------------------
-- Reply on a link
--
-- The writer `author_contact_id` has been waiting for since `0192`.
-- ---------------------------------------------------------------------
create or replace function public.reply_to_shared_ticket(
  p_token text, p_body text)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  l public.ticket_share_links;
  v_link uuid;
  v_state text;
  t public.tickets;
  v_id uuid;
begin
  select r.link_id, r.state into v_link, v_state
    from app.ticket_link_state(p_token) r;

  if v_state <> 'open' then
    return jsonb_build_object('state', coalesce(v_state, 'invalid'));
  end if;
  select * into l from public.ticket_share_links where id = v_link;
  if btrim(coalesce(p_body, '')) = '' then
    return jsonb_build_object('state', 'empty');
  end if;

  select * into t from public.tickets where id = l.ticket_id;

  insert into public.ticket_comments
    (org_id, ticket_id, body, is_internal, author_contact_id, channel)
  values (t.org_id, t.id, btrim(p_body),
          -- Unconditionally visible. A customer's own message landing as
          -- an internal note would be invisible to the person who sent
          -- it, and `is_internal` defaults to true.
          false,
          t.requester_contact_id, 'web')
  returning id into v_id;

  -- Deliberately not touched: `first_response_at`. The first-response
  -- target is a promise the company made about how quickly *it* would
  -- answer, and stopping that clock on the customer's own message would
  -- report a target met that nobody met.

  insert into public.ticket_events
    (org_id, ticket_id, event_type, note)
  values (t.org_id, t.id, 'requester_reply', left(btrim(p_body), 200));

  -- Off the customer's hands. `pending` pauses the clock while the
  -- company waits for an answer; the answer has arrived. `resolved` and
  -- `closed` reopen, which is what `reopened_count` counts.
  if t.status in ('pending', 'on_hold', 'resolved', 'closed') then
    perform app.transition_ticket_internal(t.id, 'open',
      'Reopened by the requester');
  end if;

  update public.ticket_share_links
     set reply_count = reply_count + 1 where id = l.id;

  return jsonb_build_object('state', 'open', 'comment_id', v_id);
end $$;

-- ---------------------------------------------------------------------
-- Who may call what
--
-- `0165`'s event trigger strips PUBLIC and anon from every new function
-- in these schemas, so the two that need `anon` are granted back
-- explicitly, and `supabase/tests/statutory.sql` asserts both that
-- nothing else was exposed and that these two still are — a link that
-- has silently stopped working is found by a customer, not by us.
-- ---------------------------------------------------------------------
revoke all on function public.share_ticket(uuid, integer, text)
  from public, anon;
grant execute on function public.share_ticket(uuid, integer, text)
  to authenticated;
revoke all on function public.revoke_ticket_share(uuid) from public, anon;
grant execute on function public.revoke_ticket_share(uuid) to authenticated;
revoke all on function app.ticket_link_state(text)
  from public, anon, authenticated;
revoke all on function app.transition_ticket_internal(
  uuid, app.ticket_status, text) from public, anon, authenticated;

revoke all on function public.open_shared_ticket(text) from public;
grant execute on function public.open_shared_ticket(text)
  to anon, authenticated;
revoke all on function public.reply_to_shared_ticket(text, text)
  from public;
grant execute on function public.reply_to_shared_ticket(text, text)
  to anon, authenticated;

-- Supabase's default privileges grant `anon` every table privilege, and
-- the select policy above is the only thing standing between an
-- anonymous request and a column of token hashes. `0094` shut the same
-- door on `document_share_links` for the same reason.
--
-- Deleting this line cannot be caught by `run_locally.sh`: the stub in
-- `_local_stack.sql` does not install Supabase's default privileges, so
-- `anon` has no grant on a new public table locally and the revoke is a
-- no-op. `supabase/tests/statutory.sql` asserts the absence anyway,
-- because it holds where it matters and costs nothing where it does
-- not. This is one of the places the stubs stop being the real thing,
-- which is what that file's own header warns about.
revoke all on public.ticket_share_links from anon;
-- And the grant the policies above need to mean anything: a policy
-- without the privilege behind it is a rule on a door nobody can reach,
-- which `supabase/tests/table_grants.sql` checks for across the schema.
grant select, update on public.ticket_share_links to authenticated;
