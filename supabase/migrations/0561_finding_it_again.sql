-- =====================================================================
-- iAkauntan :: 0561 finding it again
--
-- `0560` made the mailbox answerable, which is the point at which it
-- starts accumulating. An address a person actually uses has a few
-- thousand messages in it inside a year, and `mailbox_thread` hands
-- back the newest first and nothing else -- so "what did the supplier
-- say about the March delivery" is answered by scrolling, or by not
-- being answered.
--
-- ---------------------------------------------------------------------
-- A stored column rather than a query
--
-- `to_tsvector(...)` in the WHERE clause would work and would read the
-- body of every message in the company on every keystroke. The column
-- is computed once when the message lands, indexed with GIN, and the
-- search touches the index.
--
-- ---------------------------------------------------------------------
-- Why `english` for mail that is half in Malay
--
-- Postgres has no Malay configuration and is not going to grow one.
-- The choice is between `simple`, which stems nothing, and `english`,
-- which stems English properly and puts Malay words through an English
-- stemmer that was not built for them.
--
-- `english`, because the index and the query go through the SAME
-- configuration: whatever the stemmer does to `permohonan` it does
-- identically on both sides, so the word is still findable. What
-- `simple` costs is real and one-directional -- somebody searching
-- "invoice" would not find "invoices", which is the commonest search
-- this will ever be asked.
--
-- ---------------------------------------------------------------------
-- What is searched
--
-- Subject, body, and the address and name at the other end -- because
-- half of looking for a message is looking for who it was with. Not
-- attachments: their contents are in a private bucket and their names
-- are in another table, and a search that opened either would be a
-- second permission question answered in the wrong place.
--
-- Whose mail is searched is not asked here at all. The function is
-- invoker-rights over the two tables, so `0559`'s policy decides, and
-- a search that found a colleague's message by its subject would be
-- the same leak as reading it.
-- =====================================================================

alter table public.inbound_emails
  add column if not exists search tsvector
  generated always as (
    to_tsvector('english',
      coalesce(subject, '') || ' ' ||
      coalesce(from_email::text, '') || ' ' ||
      coalesce(from_name, '') || ' ' ||
      coalesce(body_text, ''))
  ) stored;

comment on column public.inbound_emails.search is
  'Subject, sender and body, for searching. Stored rather than computed '
  'per query: the alternative reads every body on every keystroke. 0561.';

create index if not exists inbound_emails_search_idx
  on public.inbound_emails using gin (search);

alter table public.email_outbox
  add column if not exists search tsvector
  generated always as (
    to_tsvector('english',
      coalesce(subject, '') || ' ' ||
      coalesce(to_email, '') || ' ' ||
      coalesce(body, ''))
  ) stored;

comment on column public.email_outbox.search is
  'Subject, recipient and body. The sent half of a conversation is as '
  'findable as the received half. 0561.';

create index if not exists email_outbox_search_idx
  on public.email_outbox using gin (search);

-- ---------------------------------------------------------------------
-- Looking for it
--
-- Same columns as `mailbox_thread`, because the result of a search is a
-- list of messages and the screen that draws one already exists.
--
-- `websearch_to_tsquery` rather than `plainto_tsquery`: it understands
-- quotes and OR and a leading minus, which is what somebody who has
-- used a search box expects, and -- the part that matters -- it never
-- raises on nonsense. `to_tsquery` turns a stray bracket into an error
-- dialog in front of somebody who was only typing.
--
-- A null mailbox searches every mailbox the caller can read, which is
-- what the everything-list on the screen is.
-- ---------------------------------------------------------------------
create or replace function public.search_mail(
  p_org_id uuid,
  p_query text,
  p_mailbox_id uuid default null,
  p_limit integer default 100
)
returns table (
  id           uuid,
  direction    text,
  mailbox_id   uuid,
  from_email   text,
  from_name    text,
  to_email     text,
  subject      text,
  body_text    text,
  at           timestamptz,
  handled_at   timestamptz,
  status       text
)
language sql
stable
set search_path = public, pg_temp
as $$
  with asked as (
    select websearch_to_tsquery('english', coalesce(p_query, '')) as q
  )
  select e.id, 'in'::text, e.mailbox_id, e.from_email::text, e.from_name,
         e.to_email::text, e.subject, e.body_text, e.received_at,
         e.read_at, 'received'::text
    from public.inbound_emails e, asked
   where e.org_id = p_org_id
     and (p_mailbox_id is null or e.mailbox_id = p_mailbox_id)
     and e.search @@ asked.q
  union all
  select o.id, 'out'::text, o.mailbox_id, o.from_email::text, o.from_name,
         o.to_email, o.subject, o.body, o.queued_at,
         o.sent_at, o.status
    from public.email_outbox o, asked
   where o.org_id = p_org_id
     -- Only mail somebody wrote. An invoice queued by a document is not
     -- in the mailbox and does not come back from a mailbox search;
     -- `email_outbox` holds both and the screen holds one.
     and o.mailbox_id is not null
     and (p_mailbox_id is null or o.mailbox_id = p_mailbox_id)
     and o.search @@ asked.q
   -- Newest first rather than by rank. A person looking through their
   -- own mail knows roughly when it was; `ts_rank` would put a message
   -- from two years ago above this morning's for saying the word twice.
   order by 9 desc
   limit greatest(coalesce(p_limit, 100), 1);
$$;

comment on function public.search_mail(uuid, text, uuid, integer) is
  'Mail matching a search, both directions, newest first. Invoker '
  'rights: 0559''s policies decide whose mail is searched. 0561.';

revoke all on function public.search_mail(uuid, text, uuid, integer)
  from public, anon;
grant execute on function public.search_mail(uuid, text, uuid, integer)
  to authenticated;
