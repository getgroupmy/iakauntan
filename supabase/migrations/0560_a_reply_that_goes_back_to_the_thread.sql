-- =====================================================================
-- iAkauntan :: 0560 a reply that goes back to the thread
--
-- `0328` gave a company an address and a screen to read what arrived
-- at it, and the screen says so in its own words: "there is no reply,
-- no compose and no folders, because the thing somebody actually needs
-- from an address like `hello@iakauntan.com` is to see what came in and
-- act on it somewhere else in the app."
--
-- That held while the addresses were `sales@` and `support@`. `0559`
-- made an address a person's, and an address with somebody's own name
-- on it that cannot answer anybody is a worse thing than no address:
-- the customer writes to `aisyah@`, Aisyah reads it here and replies
-- from Gmail, and the company's record of the conversation is now half
-- in one place and half in another.
--
-- So: compose and reply, over the outbox that already exists. Nothing
-- here sends. `0095`'s split is untouched — the database queues a row,
-- `send-email` drains it, and the provider key is in neither.
--
-- ---------------------------------------------------------------------
-- Three columns, and what each is for
--
--   `mailbox_id`   which address this went out from. `from_email` has
--                  carried the address itself since `0328`, and a text
--                  address cannot be asked whether it is personal. The
--                  read policy below needs to ask exactly that.
--
--   `in_reply_to`  the Message-ID of the message being answered, which
--                  is what makes a reply land under the original in the
--                  recipient's mail client rather than starting a new
--                  conversation beside it.
--
--   `thread_refs`  the same value in the `References` header. Held
--                  separately because the two headers are not the same
--                  header: `In-Reply-To` names the parent and
--                  `References` names the chain, and a client that
--                  threads on one is not obliged to look at the other.
--
-- ---------------------------------------------------------------------
-- Sent mail is as private as the mailbox it left from
--
-- `0095`'s policy is `is_org_member(org_id)`, which was right when
-- every outbox row was an invoice going to a customer. A reply sent
-- from a personal address is not that. Leaving the policy alone would
-- have given colleagues the answer while `0559` withheld the question —
-- half a conversation is enough to reconstruct the rest of it, and a
-- rule that protects the inbox and not the sent items protects nothing.
-- =====================================================================

alter table public.email_outbox
  -- Set null rather than cascade, same reasoning as `0559`'s
  -- `owner_id`: closing an address must not erase what was sent from
  -- it. The row keeps `from_email`, so the record stays legible.
  add column if not exists mailbox_id uuid
    references public.org_mailboxes (id) on delete set null,
  add column if not exists in_reply_to text,
  add column if not exists thread_refs text;

comment on column public.email_outbox.mailbox_id is
  'Which reserved address this was sent from, for mail composed by a '
  'person. Null for everything the system queues on a document''s '
  'behalf, which is every row before 0560.';

comment on column public.email_outbox.in_reply_to is
  'The Message-ID being answered. Threading: without it a reply opens '
  'a new conversation in the recipient''s mail client. 0560.';

comment on column public.email_outbox.thread_refs is
  'The References header. Named differently from in_reply_to because '
  'the two headers are different headers. 0560.';

-- `0521`'s rule, and `tenant_foreign_keys.sql` asserts it for the whole
-- schema: a table with its own `org_id` that names a row in a table
-- with one too has to say WHICH company's row it means. A plain
-- reference here would let a row on one company's books name another
-- company's address -- which the trigger from `0328` would then have to
-- be the only thing catching.
--
-- The column list on `on delete set null` is `0521`'s too: without it a
-- composite key nulls every referencing column, and the first of ours
-- is `org_id`.
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'email_outbox_mailbox_same_org') then
    alter table public.email_outbox
      add constraint email_outbox_mailbox_same_org
      foreign key (org_id, mailbox_id)
      references public.org_mailboxes (org_id, id)
      on delete set null (mailbox_id);
  end if;
end $$;

create index if not exists email_outbox_mailbox_idx
  on public.email_outbox (mailbox_id, queued_at desc)
  where mailbox_id is not null;

-- ---------------------------------------------------------------------
-- Who can see what was sent
--
-- `mailbox_id is null` is every row queued by a document: an invoice,
-- a reminder, a receipt. Those stay the company's, which is what they
-- are. A row that names a mailbox is answered by the same function
-- that answers for the inbox, so the two can never disagree about
-- whose mail it is.
-- ---------------------------------------------------------------------
drop policy if exists email_outbox_select on public.email_outbox;
create policy email_outbox_select on public.email_outbox
  for select to authenticated
  using (
    app.is_org_member(org_id)
    and (mailbox_id is null or app.may_read_mailbox(mailbox_id))
  );

-- ---------------------------------------------------------------------
-- Writing one
--
-- In `public` because the app calls it, SECURITY DEFINER because it
-- writes to a table nothing holding a user token may write to — the
-- grant on `email_outbox` is `select` and has been since `0095`.
--
-- The message being replied to is named by its row rather than by its
-- Message-ID, and that is the security decision in here. A caller who
-- could write the header directly could thread a message into a
-- conversation they were never part of, and could learn which
-- Message-IDs exist by watching which of them were accepted. Naming the
-- row instead means a reply can only join a conversation that arrived
-- at this mailbox -- and this function reads `inbound_emails` as
-- definer, so the check below is what stands in for the policy.
-- ---------------------------------------------------------------------
create or replace function public.send_from_mailbox(
  p_mailbox_id uuid,
  p_to text,
  p_subject text,
  p_body text,
  p_in_reply_to uuid default null
)
returns public.email_outbox
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_box    public.org_mailboxes;
  v_parent public.inbound_emails;
  v_to     text := lower(btrim(coalesce(p_to, '')));
  v_row    public.email_outbox;
begin
  select * into v_box from public.org_mailboxes where id = p_mailbox_id;
  if not found then
    raise exception 'There is no such mailbox' using errcode = 'P0002';
  end if;

  -- The same question `0559` asks of the inbox. Sending as an address
  -- is a stronger thing than reading it, and there is no case where
  -- somebody may send as a mailbox they may not read: what the
  -- recipient sees is that address's name over words they did not
  -- write.
  if not app.may_read_mailbox(p_mailbox_id) then
    raise exception 'That is not your mailbox' using errcode = '42501';
  end if;

  -- And read-only members read. `can_write` is the ordinary line
  -- between somebody looking at the books and somebody changing them,
  -- and mail leaving the company over its own name is on the far side
  -- of it.
  if not app.can_write(v_box.org_id) then
    raise exception 'You do not have permission to send from here'
      using errcode = '42501';
  end if;

  if v_box.status <> 'approved' then
    raise exception 'That address has not been approved yet'
      using errcode = '22023';
  end if;

  -- Deliberately loose. Address syntax is wider than anything worth
  -- writing here, and the provider will refuse what it will refuse; the
  -- point of this check is to catch the empty box and the name typed
  -- without a domain before the row is queued and a person is told it
  -- was sent.
  if v_to !~ '^[^@[:space:],]+@[^@[:space:],]+\.[^@[:space:],]+$' then
    raise exception 'That is not an email address we can send to'
      using errcode = '22023';
  end if;

  if btrim(coalesce(p_body, '')) = '' then
    raise exception 'A message needs something in it'
      using errcode = '22023';
  end if;

  if p_in_reply_to is not null then
    select * into v_parent from public.inbound_emails
     where id = p_in_reply_to;
    -- Not `may_read_mailbox(v_parent.mailbox_id)`: a reply must go back
    -- to the conversation it came from, so the parent has to be in THIS
    -- mailbox and not merely in one the sender can read.
    if not found or v_parent.mailbox_id <> p_mailbox_id then
      raise exception 'That message did not arrive at this address'
        using errcode = '22023';
    end if;
  end if;

  insert into public.email_outbox (
    org_id, mailbox_id, to_email, subject, body,
    from_email, from_name, in_reply_to, thread_refs, created_by)
  values (
    v_box.org_id,
    v_box.id,
    v_to,
    -- An empty subject is an empty subject, not a missing one: "(no
    -- subject)" in the box is what the recipient would see typed out.
    coalesce(nullif(btrim(coalesce(p_subject, '')), ''), '(no subject)'),
    p_body,
    -- Rebuilt here rather than taken from the caller. `0328`'s trigger
    -- would refuse a mismatch anyway; building it means there is
    -- nothing to refuse.
    v_box.local_part || '@' || app.mail_domain(),
    (select nullif(btrim(coalesce(p.full_name, '')), '')
       from public.profiles p where p.id = auth.uid()),
    v_parent.message_id,
    v_parent.message_id,
    auth.uid())
  returning * into v_row;

  return v_row;
end;
$$;

comment on function public.send_from_mailbox(uuid, text, text, text, uuid) is
  'Queues a message from one of the company''s addresses, optionally '
  'as a reply to something that arrived at it. Queued, never sent: '
  'send-email drains the outbox. 0560.';

revoke all on function public.send_from_mailbox(uuid, text, text, text, uuid)
  from public, anon;
grant execute on function public.send_from_mailbox(uuid, text, text, text, uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- What is in this mailbox, both directions
--
-- A reader wants the conversation, and the conversation is half in
-- `inbound_emails` and half in `email_outbox`. Joining them in the app
-- would mean two queries, two orderings and a merge done differently on
-- every screen that tried it.
--
-- SECURITY INVOKER, unusually for something this shape: both tables
-- carry policies that already answer the question correctly, and a
-- definer function here would be a second copy of the rule in `0559`
-- with nothing keeping it in step.
-- ---------------------------------------------------------------------
create or replace function public.mailbox_thread(p_mailbox_id uuid)
returns table (
  id           uuid,
  direction    text,
  from_email   text,
  from_name    text,
  to_email     text,
  subject      text,
  body_text    text,
  at           timestamptz,
  -- Read, for something that arrived; sent, for something that left.
  -- One column because both answer the same question a reader has
  -- about a line in the list: is this one done with.
  handled_at   timestamptz,
  status       text,
  message_id   text,
  in_reply_to  text
)
language sql
stable
set search_path = public, pg_temp
as $$
  select e.id, 'in'::text, e.from_email::text, e.from_name,
         e.to_email::text, e.subject, e.body_text, e.received_at,
         e.read_at, 'received'::text, e.message_id, null::text
    from public.inbound_emails e
   where e.mailbox_id = p_mailbox_id
  union all
  select o.id, 'out'::text, o.from_email::text, o.from_name,
         o.to_email, o.subject, o.body, o.queued_at,
         o.sent_at, o.status, null::text, o.in_reply_to
    from public.email_outbox o
   where o.mailbox_id = p_mailbox_id
   order by 8 desc;
$$;

comment on function public.mailbox_thread(uuid) is
  'Everything in one mailbox, received and sent, newest first. Invoker '
  'rights: the policies on both tables are the rule. 0560.';

revoke all on function public.mailbox_thread(uuid) from public, anon;
grant execute on function public.mailbox_thread(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Which addresses I can write from
--
-- The compose box needs a list, and the list is not "every mailbox this
-- company has": a clerk sitting in front of a picker containing
-- `aisyah@` will try it, and be refused at the moment they press send
-- with a message half-written. Asking here means the picker cannot
-- offer what `send_from_mailbox` will refuse, because both ask the same
-- function.
--
-- Personal first, because the address with your own name on it is the
-- one you meant.
-- ---------------------------------------------------------------------
create or replace function public.my_mailboxes(p_org_id uuid)
returns setof public.org_mailboxes
language sql
stable
set search_path = public, pg_temp
as $$
  select m.*
    from public.org_mailboxes m
   where m.org_id = p_org_id
     and m.status = 'approved'
     and app.may_read_mailbox(m.id)
   order by m.is_personal desc, m.local_part;
$$;

comment on function public.my_mailboxes(uuid) is
  'The approved addresses the caller may read and send from, personal '
  'first. The picker asks the same question send_from_mailbox does. '
  '0560.';

revoke all on function public.my_mailboxes(uuid) from public, anon;
grant execute on function public.my_mailboxes(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What the addresses end in
--
-- `app.mail_domain()` has been a setting since `0328` so a deployment
-- under another name does not need a migration edited. The app has been
-- writing `@iakauntan.com` into its own strings all the while, which is
-- the same literal the setting exists to avoid -- harmless on a screen
-- that only labels a request, and wrong the moment a compose box tells
-- somebody which address their message will arrive from.
--
-- A thin wrapper in `public` because PostgREST only reaches `public`,
-- and reading it is not a privilege: it is the domain printed on every
-- message the platform has ever sent.
-- ---------------------------------------------------------------------
create or replace function public.mail_domain()
returns text
language sql
stable
set search_path = public, pg_temp
as $$
  select app.mail_domain();
$$;

comment on function public.mail_domain() is
  'The domain reserved addresses live on, for screens that have to '
  'print one. 0560.';

revoke all on function public.mail_domain() from public, anon;
grant execute on function public.mail_domain() to authenticated;
